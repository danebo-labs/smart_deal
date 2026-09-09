import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

// Dictation capture for a certification report (Fase 5). One control, one
// status line, upload the moment recording stops.
//
//   idle ──tap──▶ recording ──tap──▶ uploading ──ok──▶ idle (card appended)
//                                        │
//                                        └──error──▶ failed ──tap / online──▶ uploading
//
// The blob lives in memory only between stop and a successful upload; it is a
// retry buffer, not persistence (plan, Fase 5 alcance). Everything durable —
// audio, transcript, corrections — is on the server, which is why every card
// on this page is (re)rendered from the database and never from local state.
//
// The private VoiceDictationChannel is a *signal* that a dictation changed;
// the card is then refetched as a Turbo Stream so the panel always shows the
// full transcript from the database, not the broadcast's preview.
const MIN_RECORDING_MS = 1000
const STATUS_RESET_MS = 2500
const MIME_CANDIDATES = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
const IN_FLIGHT = new Set(["pending", "transcribing"])

export default class extends Controller {
  static targets = ["button", "status", "micIcon", "stopIcon", "retryIcon", "card"]
  static values = {
    uploadUrl: String,
    showUrlTemplate: String,
    reportId: Number,
    labels: Object
  }

  connect() {
    this.state = "idle"
    this.pendingBlob = null
    this.pendingRefresh = new Set()
    this.cableConnectedBefore = false

    this.onOnline = () => this.#retryPendingUpload()
    this.onVisible = () => { if (document.visibilityState === "visible") this.#refreshInFlight() }
    window.addEventListener("online", this.onOnline)
    document.addEventListener("visibilitychange", this.onVisible)

    if (!this.#supported()) {
      this.#setState("unsupported", this.labelsValue.unsupported)
      this.buttonTarget.disabled = true
      return
    }

    this.#subscribe()
    this.#setState("idle", this.labelsValue.idle)
  }

  disconnect() {
    window.removeEventListener("online", this.onOnline)
    document.removeEventListener("visibilitychange", this.onVisible)
    this.#stopTimer()
    this.#releaseStream()
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
  }

  // The one control. What a tap does depends only on the current state.
  toggle() {
    switch (this.state) {
      case "idle":      return this.#startRecording()
      case "recording": return this.#stopRecording()
      case "failed":    return this.#retryPendingUpload()
      default:          return // starting / uploading: a second tap does nothing
    }
  }

  // --- recording ---------------------------------------------------------

  async #startRecording() {
    // Claimed synchronously so a second tap while the permission prompt is up
    // cannot open a second recorder.
    this.#setState("starting", this.labelsValue.idle)
    let stream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (error) {
      const denied = error?.name === "NotAllowedError" || error?.name === "SecurityError"
      this.#flash(denied ? this.labelsValue.mic_denied : this.labelsValue.mic_error)
      return
    }

    this.stream = stream
    const mimeType = MIME_CANDIDATES.find((type) => MediaRecorder.isTypeSupported(type))
    this.recorder = mimeType ? new MediaRecorder(stream, { mimeType }) : new MediaRecorder(stream)
    this.chunks = []
    this.recorder.addEventListener("dataavailable", (event) => { if (event.data.size > 0) this.chunks.push(event.data) })
    this.recorder.addEventListener("stop", () => this.#recordingStopped())

    this.startedAt = Date.now()
    this.recorder.start(1000)
    this.#setState("recording", this.#recordingLabel(0))
    this.timer = setInterval(() => this.statusTarget.textContent = this.#recordingLabel(this.#elapsedMs()), 250)
  }

  #stopRecording() {
    if (this.recorder?.state === "inactive") return
    this.#stopTimer()
    this.recorder.stop()
  }

  #recordingStopped() {
    const elapsedMs = this.#elapsedMs()
    const mimeType = this.recorder.mimeType || this.chunks[0]?.type || "audio/webm"
    const blob = new Blob(this.chunks, { type: mimeType })
    this.#releaseStream()

    // A glove double-tap is a ~300ms recording of nothing: don't bill it.
    if (elapsedMs < MIN_RECORDING_MS || blob.size === 0) {
      this.#flash(this.labelsValue.too_short)
      return
    }

    this.pendingBlob = { blob, mimeType, durationSeconds: Math.max(1, Math.round(elapsedMs / 1000)) }
    this.#upload()
  }

  // --- upload-first ------------------------------------------------------

  async #upload() {
    if (!this.pendingBlob) return
    this.#setState("uploading", this.labelsValue.uploading)

    const { blob, mimeType, durationSeconds } = this.pendingBlob
    const form = new FormData()
    form.append("audio", blob, `dictado.${this.#extensionFor(mimeType)}`)
    form.append("duration_seconds", String(durationSeconds))

    try {
      const response = await fetch(this.uploadUrlValue, {
        method: "POST",
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
        },
        credentials: "same-origin",
        body: form
      })
      if (!response.ok) throw new Error(`upload failed: ${response.status}`)

      window.Turbo?.renderStreamMessage(await response.text())
      this.pendingBlob = null
      this.#flash(this.labelsValue.uploaded)
      // A broadcast may have arrived before the card existed in the DOM.
      this.pendingRefresh.forEach((id) => this.#refresh(id))
      this.pendingRefresh.clear()
    } catch (error) {
      console.warn("voice-dictation: upload failed, keeping the recording for retry", error)
      this.#setState("failed", this.labelsValue.upload_failed)
    }
  }

  #retryPendingUpload() {
    if (this.state === "failed" && this.pendingBlob) this.#upload()
  }

  // --- refresh from the server -------------------------------------------

  #subscribe() {
    const controller = this
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create("VoiceDictationChannel", {
      connected() {
        // A reconnect (the socket dies when a phone locks) may have swallowed
        // a broadcast: re-read whatever is still in flight. Not on first
        // connect — the page was just rendered from the database.
        if (controller.cableConnectedBefore) controller.#refreshInFlight()
        controller.cableConnectedBefore = true
      },
      received(data) {
        if (Number(data.certification_report_id) !== controller.reportIdValue) return
        controller.#refresh(data.voice_dictation_id)
      }
    })
  }

  #refreshInFlight() {
    this.cardTargets
      .filter((card) => IN_FLIGHT.has(card.dataset.status))
      .forEach((card) => this.#refresh(card.dataset.dictationId))
  }

  async #refresh(id) {
    if (!this.cardTargets.some((card) => card.dataset.dictationId === String(id))) {
      this.pendingRefresh.add(id)
      return
    }

    try {
      const response = await fetch(this.showUrlTemplateValue.replace(":id", id), {
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
        },
        credentials: "same-origin"
      })
      if (response.ok) window.Turbo?.renderStreamMessage(await response.text())
    } catch (error) {
      console.warn("voice-dictation: refresh failed", error)
    }
  }

  // --- the single status element ----------------------------------------

  #setState(state, label) {
    this.state = state
    this.statusTarget.textContent = label
    this.buttonTarget.dataset.state = state
    this.buttonTarget.disabled = state === "starting" || state === "uploading" || state === "unsupported"

    const recording = state === "recording"
    const failed = state === "failed"
    this.micIconTarget.classList.toggle("hidden", recording || failed)
    this.stopIconTarget.classList.toggle("hidden", !recording)
    this.retryIconTarget.classList.toggle("hidden", !failed)
    this.buttonTarget.setAttribute("aria-label",
      recording ? this.labelsValue.stop : failed ? this.labelsValue.retry_upload : this.labelsValue.record)
  }

  // Transient message, then back to idle.
  #flash(label) {
    this.#setState("idle", label)
    clearTimeout(this.flashTimer)
    this.flashTimer = setTimeout(() => {
      if (this.state === "idle") this.statusTarget.textContent = this.labelsValue.idle
    }, STATUS_RESET_MS)
  }

  #recordingLabel(elapsedMs) {
    const total = Math.floor(elapsedMs / 1000)
    const time = `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`
    return this.labelsValue.recording.replace("%{time}", time)
  }

  // --- helpers -----------------------------------------------------------

  #supported() {
    return typeof MediaRecorder !== "undefined" && !!navigator.mediaDevices?.getUserMedia
  }

  #extensionFor(mimeType) {
    if (mimeType.includes("mp4")) return "m4a"
    if (mimeType.includes("ogg")) return "ogg"
    return "webm"
  }

  #elapsedMs() {
    return this.startedAt ? Date.now() - this.startedAt : 0
  }

  #stopTimer() {
    clearInterval(this.timer)
    this.timer = null
  }

  #releaseStream() {
    this.stream?.getTracks().forEach((track) => track.stop())
    this.stream = null
  }
}
