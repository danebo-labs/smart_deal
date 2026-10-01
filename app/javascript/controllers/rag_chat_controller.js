// app/javascript/controllers/rag_chat_controller.js

import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { renderSources } from "rag/sources_renderer"
import { formatAnswerForWeb, renderVerificationNotice } from "rag/answer_presenter"
import { hasSelectableEvidenceCards, renderEvidenceResolution } from "rag/evidence_cards_renderer"

export default class extends Controller {
  static targets = ["input", "sendButton", "messages", "chatContainer", "fileInput", "filePreview", "imageThumb", "docIcon", "fileName", "inputStack", "archivosTabBtn", "chatTabBtn", "archivosPanel", "chatPanel", "sourcesBadge"]
  // locale: chat chrome's own language state (notices/invites/nudges/errors).
  // Deliberately NOT derived from document.documentElement.lang — that reflects
  // the Devise auth-time locale switcher (session[:locale]), which must never
  // leak into the response-language policy (P0 idioma). Defaults to Spanish and
  // only moves to "en" when the server tells us the actual response_locale for
  // a given answer (JSON from /rag/ask or the photo_analyzed KbSync broadcast).
  static values = { showSources: Boolean, evidenceCards: Boolean, resolutionCopy: Object, locale: { type: String, default: "es" } }

  static MAX_IMAGE_SIZE = 3.75 * 1024 * 1024  // 3.75 MB (Bedrock KB ingest limit, after compression)
  static MAX_IMAGE_INPUT_SIZE = 25 * 1024 * 1024  // 25 MB (raw camera file before Canvas)
  static MAX_DOC_SIZE = 50 * 1024 * 1024     // 50 MB (Bedrock KB limit for documents)
  static SUPPORTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]
  static SUPPORTED_DOC_TYPES = ["text/plain", "text/markdown", "text/html", "text/csv", "application/pdf", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/msword", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-excel", "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation"]
  static DOC_EXTENSIONS = [".txt", ".md", ".html", ".csv", ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx"]
  static BINARY_DOC_EXTENSIONS = [".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx"]

  // First warm nudge shown inside the loading bubble — upload: if `indexed` has not
  // arrived; text query: if `ask()` has not resolved. Gives the technician human
  // company while waiting on flaky field connections.
  static CHAT_WARM_NUDGE_MS = 15 * 1000

  // Last-resort stall notice for text queries if `ask()` still hasn't resolved.
  // Prompts reload because this usually means the request or response got stuck.
  // WebSockets can drop on flaky mobile networks (technician inside an elevator
  // shaft) and Solid Cable does not replay missed messages.
  static CHAT_STALL_HINT_MS = 90 * 1000

  // Uploads can include long manuals that finish through async Batch before the
  // KB `indexed` event. Give them more room before showing a recovery hint.
  static CHAT_UPLOAD_STALL_HINT_MS = 3 * 60 * 1000

  // Back-compat aliases so the indexing path keeps working without rename churn.
  static get INDEXING_NUDGE_MS() { return this.CHAT_WARM_NUDGE_MS }
  static get INDEXING_STALL_MS() { return this.CHAT_UPLOAD_STALL_HINT_MS }

  // Typing dots inside the assistant bubble while waiting for KB indexing or retry copy.
  static INDEXING_TYPING_DOTS_HTML =
    `<span style="display:inline-flex;gap:5px;align-items:center;padding:2px 0;">` +
    `<span class="chat-typing-dot"></span>` +
    `<span class="chat-typing-dot"></span>` +
    `<span class="chat-typing-dot"></span>` +
    `</span>`

  // SVG icons for message avatars (mobile + desktop)
  static USER_SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>`
  static BOT_SVG  = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/></svg>`

  connect() {
    this.pendingFile = null
    this.pendingFieldPhotoId = null
    this.pendingPhotoCorrelationId = null
    this.pendingUploadType = null
    this.indexingLoadingId = null
    this.kbSyncInProgress = false
    this.retryNoticeId = null
    this.indexingNudgeTimer = null
    this.indexingStallTimer = null
    this.indexingStallNoticeId = null
    this.queryNudgeTimer = null
    this.queryStallTimer = null
    this.queryStallNoticeId = null
    this._activeMobileTab = "chat"
    this._focusQueue = Promise.resolve()
    this._focusBusy = 0
    this._focusSawFailure = false
    this._documentPinWait = null
    this._resolveDocumentPinWait = null
    this.subscribeToKbSync()
    this.setupMobileTabs()
    this.setupKeyboardLift()
    // Auto-focus only on desktop. On mobile, programmatic focus after a
    // navigation (e.g. Devise login redirect) opens the on-screen keyboard
    // immediately, shifting the layout up and hiding the nav + tab bar.
    if (window.innerWidth >= 768) {
      this.inputTarget?.focus()
    }
  }

  disconnect() {
    this.kbSyncSubscription?.unsubscribe()
    window.removeEventListener("resize", this._onResize)
    this.teardownKeyboardLift()
    this.clearIndexingNudgeTimer()
    this.clearIndexingStallTimer()
    this.clearQueryNudgeTimer()
    this.clearQueryStallTimer()
  }

  subscribeToKbSync() {
    if (window.location.pathname !== "/" && window.location.pathname !== "/home") return

    const controller = this
    const consumer = createConsumer()
    this.kbSyncSubscription = consumer.subscriptions.create("KbSyncChannel", {
      received(data) {
        controller._setLocale(data.response_locale)

        if (data.status === "photo_analyzed") {
          if (!controller.matchesPendingPhoto(data)) return

          controller.kbSyncInProgress = false
          controller.clearIndexingNudgeTimer()
          controller.clearRetryFallbackNotice()
          controller.clearIndexingStallTimer()
          if (controller.indexingLoadingId) {
            controller.removeMessage(controller.indexingLoadingId)
            controller.indexingLoadingId = null
          }
          controller.addImageSummaryMessage(data)
          controller.pendingPhotoCorrelationId = null
          controller.pendingUploadType = null
          return
        }

        if (data.status === "photo_question_answered") {
          if (!controller.matchesPendingPhoto(data)) return

          controller.kbSyncInProgress = false
          controller.clearIndexingNudgeTimer()
          controller.clearRetryFallbackNotice()
          controller.clearIndexingStallTimer()
          if (controller.indexingLoadingId) {
            controller.removeMessage(controller.indexingLoadingId)
            controller.indexingLoadingId = null
          }
          controller.addPhotoQuestionAnswer(data)
          controller.pendingPhotoCorrelationId = null
          controller.pendingUploadType = null
          return
        }

        if (data.status === "failed" && data.correlation_id?.startsWith("photo:")) {
          if (!controller.matchesPendingPhoto(data)) return

          controller.kbSyncInProgress = false
          controller.clearIndexingNudgeTimer()
          controller.clearRetryFallbackNotice()
          controller.clearIndexingStallTimer()
          if (controller.indexingLoadingId) {
            controller.removeMessage(controller.indexingLoadingId)
            controller.indexingLoadingId = null
          }
          if (data.message) controller.addMessage(data.message, "error")
          controller.pendingPhotoCorrelationId = null
          controller.pendingUploadType = null
          return
        }

        if (data.status === "retrying") {
          controller.updateIndexingLoadingForRetry(data)
          controller.clearIndexingNudgeTimer()
          controller.clearIndexingStallTimer()
          controller.startIndexingStallTimer()
          return
        }

        if (data.status === "partial_failed") {
          if (data.message) controller.addMessage(data.message, "assistant")
          return
        }

        if (data.status === "indexed" && data.processing_scope === "urgent_pages") {
          controller.clearIndexingNudgeTimer()
          controller.clearRetryFallbackNotice()
          controller.clearIndexingStallTimer()
          controller.refreshDocuments()
          controller.addIndexedMessage(data)
          if (controller.indexingLoadingId) {
            controller.setIndexingLoadingAcknowledgment(controller._indexingWarmCopy("full"))
            controller.startIndexingNudgeTimer()
            controller.startIndexingStallTimer()
          }
          return
        }

        if (data.status === "indexed" || data.status === "failed") {
          controller.kbSyncInProgress = false
          controller.clearIndexingNudgeTimer()
          controller.clearRetryFallbackNotice()
          controller.clearIndexingStallTimer()
          if (controller.indexingLoadingId) {
            controller.removeMessage(controller.indexingLoadingId)
            controller.indexingLoadingId = null
          }
          controller.refreshDocuments()
          if (data.status === "indexed") {
            if (data.summary) {
              controller.addImageSummaryMessage(data)
            } else {
              controller.addIndexedMessage(data)
            }
          } else if (data.message) {
            controller.addMessage(data.message, "error")
          }

          controller.releaseDocumentPinWait()
          controller.pendingUploadType = null
        }
      }
    })
  }

  // Serial pin/unpin. A rejected request does not stop the next one.
  enqueueFocusMutation(task) {
    this._focusBusy += 1
    const run = this._focusQueue.then(() => task(), () => task())
    this._focusQueue = run.catch(() => {})
    return run.finally(() => {
      this._focusBusy -= 1
    })
  }

  beginDocumentPinWait() {
    if (this._documentPinWait) return

    this._documentPinWait = new Promise((resolve) => {
      this._resolveDocumentPinWait = resolve
    })
  }

  releaseDocumentPinWait() {
    const resolve = this._resolveDocumentPinWait
    this._documentPinWait = null
    this._resolveDocumentPinWait = null
    resolve?.()
  }

  // Ask waits for the pin the technician just made, and for their own upload
  // to finish selecting. A failed pin keeps the typed question. A failed or
  // stalled upload releases the wait and the question can go out.
  async awaitDocumentFocus() {
    if (this._focusBusy > 0) {
      this._focusSawFailure = false
      let guard = 0
      while (this._focusBusy > 0 && guard < 30) {
        const queue = this._focusQueue
        await queue
        guard += 1
      }
      if (this._focusSawFailure) return false
    }

    if (this._documentPinWait) await this._documentPinWait
    return true
  }

  clickAttach() {
    this.fileInputTarget.click()
  }

  selectFile(event) {
    const file = event.target.files[0]
    if (!file) return

    const isImage = this.constructor.SUPPORTED_IMAGE_TYPES.includes(file.type)
    const isDoc = this.constructor.SUPPORTED_DOC_TYPES.includes(file.type) ||
      this.constructor.DOC_EXTENSIONS.some(ext => file.name.toLowerCase().endsWith(ext))

    if (!isImage && !isDoc) {
      this.addMessage("Formato no soportado. Imágenes: PNG, JPEG, GIF o WebP (máx. 3.75 MB). Documentos: .txt, .md, .html, .csv, .pdf, .doc, .docx, .xls, .xlsx, .ppt, .pptx (máx. 50 MB).", "error")
      this.removeFile()
      return
    }

    const maxSize = isImage ? this.constructor.MAX_IMAGE_INPUT_SIZE : this.constructor.MAX_DOC_SIZE
    if (file.size > maxSize) {
      const msg = isImage
        ? "La imagen excede el límite de 25 MB. Comprímela o reduce su tamaño."
        : "El documento excede el límite de 50 MB."
      this.addMessage(msg, "error")
      this.removeFile()
      return
    }

    if (isImage) {
      const reader = new FileReader()
      reader.onload = (e) => {
        this.compressImageOnClient(e.target.result).then(({ base64, dataUrl, bytes }) => {
          if (bytes > this.constructor.MAX_IMAGE_SIZE) {
            this.addMessage("La imagen excede el límite de 3.75 MB (Knowledge Base). Comprímela o reduce su tamaño.", "error")
            this.removeFile()
            return
          }
          this.pendingFile = { data: base64, media_type: "image/jpeg", filename: file.name, type: "image" }
          this.showPreview(dataUrl, file.name, "image")
        }).catch(() => {
          // Fallback: send as-is if Canvas fails (e.g. cross-origin taint)
          if (file.size > this.constructor.MAX_IMAGE_SIZE) {
            this.addMessage("La imagen excede el límite de 3.75 MB (Knowledge Base). Comprímela o reduce su tamaño.", "error")
            this.removeFile()
            return
          }
          const base64Data = e.target.result.split(",")[1]
          this.pendingFile = { data: base64Data, media_type: file.type, filename: file.name, type: "image" }
          this.showPreview(e.target.result, file.name, "image")
        })
      }
      reader.readAsDataURL(file)
    } else {
      const isBinary = this.constructor.BINARY_DOC_EXTENSIONS.some(ext => file.name.toLowerCase().endsWith(ext))
      if (isBinary) {
        file.arrayBuffer().then((buffer) => {
          const base64Data = this.arrayBufferToBase64(buffer)
          const mimeType = this.getDocMimeType(file.name, file.type)
          this.pendingFile = { data: base64Data, media_type: mimeType, filename: file.name, type: "document" }
          this.showPreview(null, file.name, "document")
        }).catch(() => {
          this.addMessage("Error al leer el archivo.", "error")
          this.removeFile()
        })
      } else {
        const reader = new FileReader()
        reader.onload = (e) => {
          const text = e.target.result
          const base64Data = btoa(unescape(encodeURIComponent(text)))
          const mimeType = this.getDocMimeType(file.name, file.type)
          this.pendingFile = { data: base64Data, media_type: mimeType, filename: file.name, type: "document" }
          this.showPreview(null, file.name, "document")
        }
        reader.readAsText(file, "UTF-8")
      }
    }
  }

  getDocMimeType(filename, fallbackType) {
    const ext = (filename || "").toLowerCase().split(".").pop()
    const map = {
      txt: "text/plain", md: "text/markdown", html: "text/html", csv: "text/csv",
      pdf: "application/pdf", doc: "application/msword", docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      xls: "application/vnd.ms-excel", xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      ppt: "application/vnd.ms-powerpoint", pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    }
    return map[ext] || fallbackType || "application/octet-stream"
  }

  arrayBufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer)
    let binary = ""
    const chunk = 8192
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk))
    }
    return btoa(binary)
  }

  // Compresses an image client-side via Canvas before uploading.
  // Resizes to MAX_DIMENSION and encodes as JPEG at the given quality.
  // Returns { base64: string, dataUrl: string, bytes: number } — bytes is blob.size,
  // the same magnitude the server compares against MAX_BINARY_BYTES.
  compressImageOnClient(dataUrl, maxDim = 1024, quality = 0.82) {
    return new Promise((resolve, reject) => {
      const img = new Image()
      img.onerror = reject
      img.onload = () => {
        let { width, height } = img
        if (width > maxDim || height > maxDim) {
          const ratio = Math.min(maxDim / width, maxDim / height)
          width  = Math.round(width  * ratio)
          height = Math.round(height * ratio)
        }
        const canvas = document.createElement("canvas")
        canvas.width  = width
        canvas.height = height
        canvas.getContext("2d").drawImage(img, 0, 0, width, height)
        canvas.toBlob((blob) => {
          if (!blob) { reject(new Error("Canvas toBlob failed")); return }
          const reader = new FileReader()
          reader.onerror = reject
          reader.onload = (e) => {
            const resultDataUrl = e.target.result
            resolve({ base64: resultDataUrl.split(",")[1], dataUrl: resultDataUrl, bytes: blob.size })
          }
          reader.readAsDataURL(blob)
        }, "image/jpeg", quality)
      }
      img.src = dataUrl
    })
  }

  showPreview(imageDataUrl, name, fileType) {
    this.imageThumbTarget.style.display = fileType === "image" ? "block" : "none"
    this.imageThumbTarget.src = imageDataUrl || ""
    this.docIconTarget.style.display = fileType === "document" ? "block" : "none"
    this.fileNameTarget.textContent = name
    this.filePreviewTarget.style.display = "block"
  }

  removeFile() {
    this.pendingFile = null
    this.fileInputTarget.value = ""
    this.filePreviewTarget.style.display = "none"
  }

  async sendMessage(event) {
    event.preventDefault()

    const question = this.inputTarget.value.trim()
    const hasFile = this.pendingFile !== null

    if (!question && !hasFile) return
    if (!await this.awaitDocumentFocus()) return

    this.switchToChatTab()
    this.disableForm()

    if (hasFile) {
      if (this.pendingFile.type === "image") {
        this.addImageMessage(this.imageThumbTarget.src, question)
      } else {
        this.addDocumentMessage(this.pendingFile.filename, question)
      }
    } else {
      this.addMessage(question, "user")
    }

    this.inputTarget.value = ""
    const fileToSend = this.pendingFile
    this.removeFile()
    this.pendingFieldPhotoId = null

    const loadingId = this.addLoadingMessage()
    const ragTextQuery = !fileToSend
    if (ragTextQuery) this.startQueryWaitTimers(loadingId)

    try {
      const data = await this.ask(question, fileToSend)
      this._setLocale(data.response_locale)

      if (data.status !== "success") {
        this.removeMessage(loadingId)
        throw new Error(data.message || "Unknown error")
      }

      // For image/document uploads, KEEP the same dots bubble alive until
      // KbSyncChannel signals "indexed" (or "failed"). Show an immediate warm
      // acknowledgment inside the bubble, then a nudge at 10 s if still waiting.
      if (data.images_uploaded?.length) {
        this.indexingLoadingId = loadingId
        this.kbSyncInProgress = true
        this.pendingUploadType = "image"
        this.pendingPhotoCorrelationId = data.correlation_id
        this.setIndexingLoadingAcknowledgment(data.answer || this._indexingWarmCopy("ack"))
        this.startIndexingNudgeTimer()
        this.startIndexingStallTimer()
        this.refreshDocuments()
      } else if (data.documents_uploaded?.length) {
        this.indexingLoadingId = loadingId
        this.kbSyncInProgress = true
        this.pendingUploadType = "document"
        this.beginDocumentPinWait()
        const uploadAck = question ? this._indexingWarmCopy("ack") : (data.answer || this._indexingWarmCopy("ack"))
        this.setIndexingLoadingAcknowledgment(uploadAck)
        this.startIndexingNudgeTimer()
        this.startIndexingStallTimer()
        this.refreshDocuments()
        if (question) this.renderAssistantAnswer(data)
      } else {
        this.removeMessage(loadingId)
        this.renderAssistantAnswer(data)
      }
    } catch (error) {
      this.removeMessage(loadingId)
      const lang = this.localeValue
      const friendlyError = lang.startsWith("en")
        ? "Something went wrong on my end. Please try again in a moment."
        : "Algo falló de mi parte. Inténtalo de nuevo en un momento."
      this.addMessage(friendlyError, "error")
    } finally {
      if (ragTextQuery) {
        this.clearQueryNudgeTimer()
        this.clearQueryStallTimer()
      }
      this.enableForm()
    }
  }

  async ask(question, file = null) {
    const payload = { question }
    if (file) {
      if (file.type === "image") {
        payload.image = { data: file.data, media_type: file.media_type, filename: file.filename }
      } else {
        payload.document = { data: file.data, media_type: file.media_type, filename: file.filename }
      }
    }
    if (this.pendingFieldPhotoId && !file) payload.field_photo_id = this.pendingFieldPhotoId
    const response = await fetch("/rag/ask", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Accept-Language": this.localeValue,
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
      },
      credentials: "same-origin",
      body: JSON.stringify(payload)
    })

    if (!response.ok) {
      throw new Error(`Server error (${response.status})`)
    }

    return response.json()
  }

  /* UI helpers */

  disableForm() {
    this.inputTarget.disabled = true
    this.sendButtonTarget?.setAttribute("disabled", true)
  }

  enableForm() {
    this.inputTarget.disabled = false
    this.sendButtonTarget?.removeAttribute("disabled")
    if (window.innerWidth >= 768) {
      this.inputTarget.focus()
    }
  }

  matchesPendingPhoto(data) {
    return Boolean(this.pendingPhotoCorrelationId) &&
      data.correlation_id === this.pendingPhotoCorrelationId
  }

  // Updates the chat chrome's own locale state from a server-provided
  // response_locale (ask() JSON or a KbSync broadcast). Ignores anything else
  // (undefined, unsupported codes) so a single bad payload can't wedge the UI.
  _setLocale(candidate) {
    const normalized = String(candidate || "").toLowerCase()
    if (normalized === "en" || normalized === "es") this.localeValue = normalized
  }

  // Segmented mobile tab button states (design/v0-mobile/mobile-home-shell.tsx)
  static MOBILE_TAB_ACTIVE_CLASSES = [
    "bg-[hsl(217,91%,50%)]", "text-white", "shadow-md",
    "shadow-[hsl(217,91%,50%,0.35)]"
  ]
  static MOBILE_TAB_INACTIVE_CLASSES = [
    "bg-white", "text-[hsl(215,20%,42%)]", "shadow-sm",
    "border", "border-[hsl(215,20%,88%)]"
  ]
  static MOBILE_TAB_BADGE_ACTIVE_CLASSES = ["bg-white/25", "text-white"]
  static MOBILE_TAB_BADGE_INACTIVE_CLASSES = ["bg-[hsl(217,91%,50%)]", "text-white"]

  setupMobileTabs() {
    this.updateMobileTabUI()
    this.updateSourcesBadge()
    this._onResize = () => this.updateMobileTabUI()
    window.addEventListener("resize", this._onResize, { passive: true })
  }

  switchToArchivosTab() {
    this._activeMobileTab = "archivos"
    this.updateMobileTabUI()
  }

  switchToChatTab() {
    this._activeMobileTab = "chat"
    this.updateMobileTabUI()
  }

  updateMobileTabUI() {
    const isMobile = window.innerWidth < 768
    const showArchivos = this._activeMobileTab === "archivos"

    if (this.hasArchivosPanelTarget) {
      if (isMobile) {
        this.archivosPanelTarget.classList.toggle("hidden", !showArchivos)
      }
      // On desktop md:hidden CSS hides it regardless — no JS override needed
    }

    if (this.hasChatPanelTarget) {
      if (isMobile) {
        this.chatPanelTarget.classList.toggle("hidden", showArchivos)
      } else {
        this.chatPanelTarget.classList.remove("hidden")
      }
    }

    if (this.hasArchivosTabBtnTarget) {
      this._applyMobileTabBtnState(this.archivosTabBtnTarget, showArchivos && isMobile)
    }

    if (this.hasChatTabBtnTarget) {
      this._applyMobileTabBtnState(this.chatTabBtnTarget, !showArchivos && isMobile)
    }
  }

  _applyMobileTabBtnState(btn, active) {
    this.constructor.MOBILE_TAB_ACTIVE_CLASSES.forEach((cls) => {
      btn.classList.toggle(cls, active)
    })
    this.constructor.MOBILE_TAB_INACTIVE_CLASSES.forEach((cls) => {
      btn.classList.toggle(cls, !active)
    })
    btn.setAttribute("aria-selected", active ? "true" : "false")

    const badge = btn.querySelector("[data-rag-chat-target='sourcesBadge']")
    if (!badge) return

    this.constructor.MOBILE_TAB_BADGE_ACTIVE_CLASSES.forEach((cls) => {
      badge.classList.toggle(cls, active)
    })
    this.constructor.MOBILE_TAB_BADGE_INACTIVE_CLASSES.forEach((cls) => {
      badge.classList.toggle(cls, !active)
    })
  }

  updateSourcesBadge() {
    if (!this.hasSourcesBadgeTarget) return
    if (!this._focusIds) {
      const raw = this.element.dataset.focusIds
      const ids = raw ? JSON.parse(raw) : []
      this._focusIds = new Set(ids.map(String))
    }

    // A rendered row is the check the technician can see. A selected manual
    // that is not on this page stays in the count.
    const rendered = new Map()
    this.element.querySelectorAll("[data-doc-id]").forEach((el) => {
      rendered.set(String(el.dataset.docId), el.dataset.selected === "true")
    })
    rendered.forEach((selected, id) => {
      if (selected) this._focusIds.add(id)
      else this._focusIds.delete(id)
    })

    const count = String(this._focusIds.size)
    this.sourcesBadgeTargets.forEach((badge) => {
      badge.textContent = count
      badge.style.display = "inline-flex"
      badge.setAttribute("aria-label", `${count} seleccionados`)
    })
  }

  // ── Keyboard lift (mobile only) ───────────────────────────────────────────
  // Uses the VisualViewport API to detect the on-screen keyboard and exposes
  // its height as the CSS variable --kbd-h on <html>. CSS in application.css
  // (.chat-input-stack) consumes that variable to translate the input bar up
  // and keep the textarea anchored above the keyboard. The rest of the UI
  // (KB list + chat messages) does NOT move — body height is locked to 100svh.
  setupKeyboardLift() {
    const vv = window.visualViewport
    if (!vv) return  // very old browsers — silently no-op (layout still works)

    this._onVvChange = () => {
      // Keyboard height = layout viewport bottom - visual viewport bottom.
      // Clamp at 0 so non-keyboard resizes (URL bar, rotation) don't lift.
      const layoutH = window.innerHeight
      const visualBottom = vv.height + vv.offsetTop
      const kbdH = Math.max(0, Math.round(layoutH - visualBottom))
      document.documentElement.style.setProperty("--kbd-h", `${kbdH}px`)
    }

    vv.addEventListener("resize", this._onVvChange)
    vv.addEventListener("scroll", this._onVvChange)
    this._onVvChange()
  }

  teardownKeyboardLift() {
    const vv = window.visualViewport
    if (!vv || !this._onVvChange) return
    vv.removeEventListener("resize", this._onVvChange)
    vv.removeEventListener("scroll", this._onVvChange)
    document.documentElement.style.removeProperty("--kbd-h")
    this._onVvChange = null
  }

  // ── Message row builder (avatar + bubble wrapper) ─────────────────────────
  // Each message is wrapped in a flex row:
  //   user      → flex-row-reverse (avatar right, bubble left, both pushed right)
  //   assistant → flex-row (avatar left, bubble right)
  //   system    → centered, no avatar

  _buildMessageRow(type, id = null, temporary = false) {
    const isUser   = type === "user"
    const isSystem = type === "system"

    const row = document.createElement("div")
    row.className = `chat-row chat-row-${isUser ? "user" : isSystem ? "system" : "assistant"}`
    if (id) row.id = id
    if (temporary) row.dataset.temporary = true

    if (!isSystem) {
      const avatar = document.createElement("div")
      avatar.className = `chat-avatar ${isUser ? "chat-avatar-user" : "chat-avatar-bot"}`
      avatar.innerHTML = isUser ? this.constructor.USER_SVG : this.constructor.BOT_SVG
      row.appendChild(avatar)
    }

    const bubble = document.createElement("div")
    bubble.className = `chat-message chat-message-${type}`
    row.appendChild(bubble)

    return row
  }

  nextMessageId() {
    this._messageSeq = (this._messageSeq || 0) + 1
    return `msg-${Date.now()}-${this._messageSeq}`
  }

  addLoadingMessage() {
    const id  = this.nextMessageId()
    const row = this._buildMessageRow("assistant", id, true)
    row.querySelector(".chat-message").innerHTML =
      `<div style="display:flex;flex-direction:column;gap:6px;" role="status" aria-live="polite">` +
      this.constructor.INDEXING_TYPING_DOTS_HTML +
      `</div>`
    this.messagesTarget.appendChild(row)
    this.scroll()
    return id
  }

  addMessage(text, type, temporary = false) {
    const id  = this.nextMessageId()
    const row = this._buildMessageRow(type, id, temporary)
    row.querySelector(".chat-message").textContent = text
    this.messagesTarget.appendChild(row)
    this.scroll()
    return id
  }

  addMessageHtml(html, type) {
    const row = this._buildMessageRow(type)
    row.querySelector(".chat-message").innerHTML = html
    this.messagesTarget.appendChild(row)
    this.scroll()
    return row
  }

  addImageMessage(imageSrc, text) {
    const row = this._buildMessageRow("user")
    const bubble = row.querySelector(".chat-message")
    let html = `<img src="${imageSrc}" style="max-width:200px;max-height:150px;border-radius:8px;display:block;margin-bottom:4px;" />`
    if (text) html += `<span>${this.escapeHtml(text)}</span>`
    bubble.innerHTML = html
    this.messagesTarget.appendChild(row)
    this.scroll()
  }

  addDocumentMessage(filename, text) {
    const row = this._buildMessageRow("user")
    const bubble = row.querySelector(".chat-message")
    let html = `<span style="font-size:12px;color:#4a5568;">📄 ${this.escapeHtml(filename)}</span>`
    if (text) html += `<br><span>${this.escapeHtml(text)}</span>`
    bubble.innerHTML = html
    this.messagesTarget.appendChild(row)
    this.scroll()
  }

  // Drops only the requested row. Upload indexing notices can remain active
  // while a separate text query is being answered.
  removeMessage(id) {
    document.getElementById(id)?.remove()
  }

  clearRetryFallbackNotice() {
    if (!this.retryNoticeId) return
    document.getElementById(this.retryNoticeId)?.remove()
    this.retryNoticeId = null
  }

  // KbSync `retrying`: update the active indexing spinner with dots + server message.
  // Every `retrying` broadcast replaces only the bubble content; dots are re-injected so
  // the animation continues. Scrolls the row into view. Fallback (no indexing bubble yet)
  // injects an equivalent dots+message assistant bubble, cleared on indexed/failed.
  _indexingWarmCopy(kind) {
    const lang = this.localeValue
    if (this.pendingUploadType === "image") {
      const photoTable = lang.startsWith("en") ? {
        ack:   "I got your photo and I'm analyzing what is directly visible.",
        nudge: "I'm still analyzing your photo — I'll show the visible details and uncertainties shortly.",
        retry: "The photo analysis is taking a little longer than usual. I'm still working on it.",
        stall: "The photo analysis is still taking a while. If nothing updates, try sending it again."
      } : {
        ack:   "Recibí tu foto y estoy analizando lo que se ve directamente.",
        nudge: "Sigo analizando tu foto — en breve te muestro los datos visibles y las incertidumbres.",
        retry: "El análisis de la foto está tardando un poco más de lo habitual. Sigo trabajando en ella.",
        stall: "El análisis de la foto sigue tardando. Si no ves novedades, intenta enviarla otra vez."
      }
      return photoTable[kind] || photoTable.retry
    }

    const table = lang.startsWith("en") ? {
      ack:   "Got your file and I'm indexing it. You can keep asking about already-indexed documents while it gets ready.",
      nudge: "Still working on your file — large documents can take a little longer in the field. You can keep asking about documents that are already indexed.",
      full:  "I already prepared the urgent pages I could match. The full manual is still indexing in the background.",
      retry: "Taking a bit longer than usual — still on your file, I'll be with you in a moment.",
      stall: "Still taking a while. If nothing updates, refresh the page — when you're back, we'll continue."
    } : {
      ack:   "Recibí tu archivo y lo estoy indexando. Puedes seguir consultando documentos ya indexados mientras queda listo.",
      nudge: "Sigo con tu archivo — los documentos grandes pueden tardar un poco más en campo. Puedes seguir preguntando sobre documentos ya indexados.",
      full:  "Ya preparé las páginas urgentes que pude asociar a tu consulta. El manual completo sigue indexándose en segundo plano.",
      retry: "Está tardando un poco más de lo habitual — sigo con tu archivo, en un momento te cuento.",
      stall: "Sigue tardando un poco. Si no ves novedades, recarga la página; cuando vuelvas, seguimos."
    }
    return table[kind] || table.retry
  }

  _queryWarmCopy(kind) {
    const lang = this.localeValue
    const table = lang.startsWith("en") ? {
      nudge: "Still working on your query — sometimes it takes a moment, especially with the connection in the field. I'll respond shortly.",
      stall: "Still taking a while. If nothing updates, refresh the page — when you're back, we'll continue."
    } : {
      nudge: "Sigo procesando tu consulta — a veces tarda un poco más por la señal en campo. En unos segundos te respondo.",
      stall: "Sigue tardando un poco. Si no ves novedades, recarga la página; cuando vuelvas, seguimos."
    }
    return table[kind] || table.nudge
  }

  updateIndexingLoadingForRetry(data) {
    const message = (data.message && data.message.trim()) || this._indexingWarmCopy("retry")

    const retryInnerHtml =
      `<div style="display:flex;flex-direction:column;gap:6px;" role="status" aria-live="polite">` +
      this.constructor.INDEXING_TYPING_DOTS_HTML +
      `<span style="font-size:13px;line-height:1.45;font-weight:500;">${this.escapeHtml(message)}</span>` +
      `</div>`

    if (this.indexingLoadingId) {
      this.clearRetryFallbackNotice()
      const row    = document.getElementById(this.indexingLoadingId)
      const bubble = row?.querySelector(".chat-message")
      if (!bubble) return

      bubble.innerHTML = retryInnerHtml
      row.scrollIntoView({ behavior: "smooth", block: "nearest" })
      this.scroll()
      return
    }

    // Fallback: no indexing bubble (race — kbSyncInProgress or late cable subscribe).
    // Reuse or create a persistent assistant bubble with the same dots+message layout.
    if (this.retryNoticeId) {
      const bubble = document.getElementById(this.retryNoticeId)?.querySelector(".chat-message")
      if (bubble) bubble.innerHTML = retryInnerHtml
    } else {
      const id  = this.nextMessageId()
      const row = this._buildMessageRow("assistant", id, false)
      row.querySelector(".chat-message").innerHTML = retryInnerHtml
      this.messagesTarget.appendChild(row)
      this.retryNoticeId = id
    }
    this.scroll()
  }

  scroll() {
    this.chatContainerTarget.scrollTop =
      this.chatContainerTarget.scrollHeight
  }

  scrollToMessageTop(element) {
    const container = this.chatContainerTarget
    const containerRect = container.getBoundingClientRect()
    const elementRect = element.getBoundingClientRect()
    container.scrollTop += elementRect.top - containerRect.top
  }

  handleKeyPress(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      if (window.innerWidth < 768) return  // mobile: Enter inserts newline, send via button
      event.preventDefault()
      this.sendMessage(event)
    }
  }

  // Click on a KB doc card. The check moves immediately. The textarea stays
  // exactly as the technician typed it. A failed request restores the check.
  toggleDocSelection(event) {
    const btn = event.currentTarget
    const docId = btn.dataset.docId
    if (!docId) return

    const wasSelected = btn.dataset.selected === "true"
    this._setSelectedUI(docId, !wasSelected)

    this.enqueueFocusMutation(async () => {
      try {
        const url = wasSelected ? `/pinned_documents/${docId}` : `/pinned_documents`
        const method = wasSelected ? "DELETE" : "POST"
        const body = wasSelected ? null : JSON.stringify({ kb_document_id: docId })
        const res = await fetch(url, {
          method,
          headers: this._jsonHeaders(),
          credentials: "same-origin",
          body
        })
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
      } catch (err) {
        this._setSelectedUI(docId, wasSelected)
        this.refreshDocuments()
        this._focusSawFailure = true
        console.error("toggleDocSelection failed:", err)
        throw err
      }
    }).catch(() => {})
  }

  // Syncs selection state for ALL buttons with the given docId (mobile + desktop panels).
  // The rag-chat controller root spans both panels, so a doc appears twice in the DOM;
  // updating only the clicked button left the hidden duplicate stale, causing badge count = 1 after deselecting all.
  _setSelectedUI(docId, isSelected) {
    const btns = this.element.querySelectorAll(`[data-doc-id="${docId}"]`)
    btns.forEach(btn => {
      btn.dataset.selected = isSelected ? "true" : "false"
      const checkbox = btn.querySelector(".kb-doc-checkbox")
      if (isSelected) {
        btn.classList.remove("border-transparent", "bg-[hsl(215,20%,96%)]")
        btn.classList.add("border-[hsl(217,91%,50%)]", "bg-[hsl(217,91%,50%,0.06)]")
        if (checkbox) {
          checkbox.classList.remove("bg-[hsl(215,20%,88%)]")
          checkbox.classList.add("bg-[hsl(217,91%,50%)]", "text-white")
          checkbox.innerHTML = `<svg style="width:14px;height:14px;display:block;" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="3"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg>`
        }
      } else {
        btn.classList.add("border-transparent", "bg-[hsl(215,20%,96%)]")
        btn.classList.remove("border-[hsl(217,91%,50%)]", "bg-[hsl(217,91%,50%,0.06)]")
        if (checkbox) {
          checkbox.classList.add("bg-[hsl(215,20%,88%)]")
          checkbox.classList.remove("bg-[hsl(217,91%,50%)]", "text-white")
          checkbox.innerHTML = ""
        }
      }
    })
    this.updateSourcesBadge()
  }

  _jsonHeaders() {
    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  renderAssistantAnswer(data) {
    // Prefer this specific answer's own response_locale (already applied via
    // _setLocale in sendMessage, but data may arrive from a caller — e.g. the
    // system test — that doesn't go through sendMessage) over the controller's
    // last-known chat locale.
    const lang = (String(data.response_locale || "").toLowerCase() || this.localeValue)
    const citations = Array.isArray(data.citations) ? data.citations : []
    // Fallback for when Haiku emitted <DOC_REFS> but no inline [n] citations —
    // no numbered references exist, so we show consulted document names instead.
    const consultedDocuments = !citations.length && Array.isArray(data.consulted_documents)
      ? data.consulted_documents
      : []
    const sourcesCitations = citations.length
      ? citations
      : consultedDocuments.map((name) => ({ filename: name }))

    const showSources = this.showSourcesValue
    const answerHtml  = formatAnswerForWeb(data.answer, citations, data.provenance_segments)
    const suggestionHtml = this.renderManualSuggestion(data.manual_suggestion)
    const focusHtml = this.renderFocusNotices(data)
    const resolutionHtml = this.evidenceCardsValue
      ? renderEvidenceResolution(data.resolution, this.resolutionCopyValue)
      : ""
    const sourcesHtml = showSources && sourcesCitations.length ? renderSources(sourcesCitations, lang) : ""
    // Guardrail del piloto (decisión #8, Fase 3): construida aparte de
    // `answerHtml` (que es lo único derivado de `data.answer`) — nunca se
    // concatena al string `answer` del JSON, sólo al host del mensaje.
    const noticeHtml = renderVerificationNotice(lang)

    const answerRow = this.addMessageHtml(answerHtml + suggestionHtml + focusHtml + resolutionHtml + sourcesHtml + noticeHtml, "assistant")
    const cardsOwnSelection = this.evidenceCardsValue && hasSelectableEvidenceCards(data.resolution)
    if (!cardsOwnSelection && Array.isArray(data.quick_replies) && data.quick_replies.length) {
      this.addMessageHtml(this.renderQuickReplies(data.quick_replies), "assistant")
    }
    this.scrollToMessageTop(answerRow)
  }

  // The card does not choose a tie and does not pin by itself.
  // A button confirms the exact row the server already bound.
  renderManualSuggestion(suggestion) {
    if (!suggestion || typeof suggestion !== "object") return ""

    const cards = Array.isArray(suggestion.cards) ? suggestion.cards.slice(0, 3) : []
    if (!cards.length) {
      if (!suggestion.message) return ""
      return `<p class="manual-suggestion-empty mt-3 text-sm leading-5 text-[hsl(215,16%,35%)]" role="status">${this.escapeHtml(suggestion.message)}</p>`
    }

    const actionLabel = suggestion.focus_action || "Usar este manual"
    const clearLabel = suggestion.focus_clear || "Quitar foco"
    const focusedStatus = suggestion.focus_status || "Manual enfocado"
    const invalidStatus = suggestion.focus_invalid || "No pude seleccionar este manual."
    const articles = cards.map((card) => this.renderManualCard(card, suggestion.correlation_id, actionLabel, clearLabel, focusedStatus)).join("")
    const tie = suggestion.tie_at_top === true ? "true" : "false"
    return `<section class="manual-suggestion mt-3 flex flex-col gap-2" aria-label="Sugerencias de manual" data-tie-at-top="${tie}" data-selected="none" data-focus-action="${this.escapeAttribute(actionLabel)}" data-focus-clear="${this.escapeAttribute(clearLabel)}" data-focus-status="${this.escapeAttribute(focusedStatus)}" data-focus-invalid="${this.escapeAttribute(invalidStatus)}">${articles}</section>`
  }

  renderManualCard(card, correlationId, actionLabel, clearLabel, focusedStatus) {
    const name = this.escapeHtml(card.display_name || "")
    const text = this.escapeHtml(card.text || "")
    const provenance = this.escapeHtml(card.provenance || "")
    const actionable = card.kb_document_id != null && card.kb_document_id !== "" && card.document_uid
    const focused = card.focused === true
    const action = actionable ? this.renderManualFocusButton(card, correlationId, focused, actionLabel, clearLabel, focusedStatus) : ""
    return `<article class="rounded-xl border border-[hsl(215,20%,88%)] bg-[hsl(215,20%,97%)] px-4 py-3" data-suggestion-label="${this.escapeAttribute(card.label || "")}" data-suggestion-scope="${this.escapeAttribute(card.knowledge_scope || "")}" data-focused="${focused ? "true" : "false"}">
        <p class="text-sm font-medium leading-5 text-[hsl(215,25%,16%)]">${name}</p>
        <p class="mt-1 text-sm leading-5 text-[hsl(215,16%,32%)]">${text}</p>
        <p class="mt-1 text-xs leading-4 text-[hsl(215,12%,42%)]">${provenance}</p>
        ${action}
      </article>`
  }

  renderManualFocusButton(card, correlationId, focused, actionLabel, clearLabel, focusedStatus) {
    const label = focused ? clearLabel : actionLabel
    const status = focused ? focusedStatus : ""
    return `<button type="button"
        class="manual-focus-action mt-3 min-h-11 w-full rounded-xl border border-[hsl(217,91%,50%)] bg-white px-4 py-2.5 text-left text-sm font-medium text-[hsl(217,91%,42%)] active:bg-[hsl(217,91%,95%)]"
        data-action="click->rag-chat#confirmManualFocus"
        data-kb-document-id="${this.escapeAttribute(String(card.kb_document_id))}"
        data-document-uid="${this.escapeAttribute(card.document_uid || "")}"
        data-correlation-id="${this.escapeAttribute(correlationId || "")}"
        data-focused="${focused ? "true" : "false"}"
        aria-pressed="${focused ? "true" : "false"}">${this.escapeHtml(label)}</button>
      <p class="manual-focus-status mt-2 text-sm leading-5 text-[hsl(215,16%,32%)]" role="status">${this.escapeHtml(status)}</p>`
  }

  renderFocusNotices(data) {
    if (!data || typeof data !== "object") return ""

    const parts = []
    const pin = data.pin_conflict && data.pin_conflict.message
    const identity = data.identity_conflict && data.identity_conflict.message
    if (pin) {
      parts.push(`<p class="pin-conflict mt-3 text-sm leading-5 text-[hsl(215,16%,32%)]" role="status">${this.escapeHtml(pin)}</p>`)
    }
    if (identity) {
      parts.push(`<p class="identity-conflict mt-3 text-sm leading-5 text-[hsl(215,16%,32%)]" role="status">${this.escapeHtml(identity)}</p>`)
    }
    return parts.join("")
  }

  async confirmManualFocus(event) {
    const button = event.currentTarget
    const article = button.closest("article")
    const section = button.closest("section")
    const docId = button.dataset.kbDocumentId
    const uid = button.dataset.documentUid
    if (!docId || !uid || button.disabled) return

    const focused = button.dataset.focused === "true"
    button.disabled = true
    this.enqueueFocusMutation(async () => {
      try {
        const correlation = button.dataset.correlationId
        const response = focused
          ? await this.unpinManualFocus(docId, uid, correlation)
          : await this.pinManualFocus(docId, uid, correlation)
        const payload = await response.json().catch(() => ({}))
        if (!response.ok) {
          this.setManualFocusStatus(article, payload.error || section?.dataset.focusInvalid || "No pude seleccionar este manual.")
          this._focusSawFailure = true
          throw new Error("focus failed")
        }
        this.setManualFocusState(button, article, section, !focused, payload.message)
        this._setSelectedUI(docId, !focused)
      } catch (error) {
        if (error?.message !== "focus failed") {
          this.setManualFocusStatus(article, section?.dataset.focusInvalid || "No pude seleccionar este manual.")
          this._focusSawFailure = true
        }
        throw error
      } finally {
        button.disabled = false
      }
    }).catch(() => {})
  }

  pinManualFocus(docId, uid, correlationId) {
    const body = { kb_document_id: docId, document_uid: uid }
    if (correlationId) body.correlation_id = correlationId
    return fetch("/pinned_documents", {
      method: "POST",
      headers: this._jsonHeaders(),
      credentials: "same-origin",
      body: JSON.stringify(body)
    })
  }

  unpinManualFocus(docId, uid, correlationId) {
    const params = new URLSearchParams({ document_uid: uid })
    if (correlationId) params.set("correlation_id", correlationId)
    return fetch(`/pinned_documents/${encodeURIComponent(docId)}?${params}`, {
      method: "DELETE",
      headers: this._jsonHeaders(),
      credentials: "same-origin"
    })
  }

  setManualFocusState(button, article, section, focused, message) {
    const action = focused
      ? (section?.dataset.focusClear || "Quitar foco")
      : (section?.dataset.focusAction || "Usar este manual")
    const status = message || (focused ? (section?.dataset.focusStatus || "Manual enfocado") : "")
    button.dataset.focused = focused ? "true" : "false"
    button.setAttribute("aria-pressed", focused ? "true" : "false")
    button.textContent = action
    if (article) article.dataset.focused = focused ? "true" : "false"
    this.setManualFocusStatus(article, status)
  }

  setManualFocusStatus(article, message) {
    const status = article?.querySelector(".manual-focus-status")
    if (status) status.textContent = message || ""
  }

  renderQuickReplies(replies, ariaLabel = "Opciones de placa") {
    const buttons = replies.slice(0, 4).map((reply) => {
      const label = typeof reply === "string" ? reply : reply.label
      const query = typeof reply === "string" ? reply : reply.query
      const safeLabel = this.escapeHtml(label || "")
      const safeQuery = this.escapeAttribute(query || label || "")
      return `<button type="button"
                data-action="click->rag-chat#sendQuickReply"
                data-query="${safeQuery}"
                class="min-h-11 w-full rounded-xl border border-[hsl(217,91%,50%)] bg-white px-4 py-2.5 text-left text-sm font-medium text-[hsl(217,91%,42%)] active:bg-[hsl(217,91%,95%)]">
                ${safeLabel}
              </button>`
    }).join("")
    return `<div class="flex w-full flex-col gap-2" aria-label="${this.escapeAttribute(ariaLabel)}">${buttons}</div>`
  }

  escapeAttribute(text) {
    return this.escapeHtml(text)
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;")
      .replace(/\n/g, "&#10;")
  }

  sendQuickReply(event) {
    const query = event.currentTarget.dataset.query
    if (!query) return

    this.inputTarget.value = query
    this.sendMessage({ preventDefault() {} })
  }

  // ── Immediate acknowledgment in the loading bubble ────────────────────────
  // Updates the dots bubble with a warm first line so the technician sees
  // human company from the very first second, not just a spinner.
  setIndexingLoadingAcknowledgment(text) {
    if (!this.indexingLoadingId) return
    const row    = document.getElementById(this.indexingLoadingId)
    const bubble = row?.querySelector(".chat-message")
    if (!bubble) return
    delete row.dataset.temporary
    bubble.innerHTML =
      `<div style="display:flex;flex-direction:column;gap:6px;" role="status" aria-live="polite">` +
      this.constructor.INDEXING_TYPING_DOTS_HTML +
      `<span style="font-size:13px;line-height:1.45;">${this.escapeHtml(text)}</span>` +
      `</div>`
  }

  // ── 15-second nudge — still waiting, stay calm ────────────────────────────
  startIndexingNudgeTimer() {
    this.clearIndexingNudgeTimer()
    this.indexingNudgeTimer = setTimeout(() => {
      if (!this.kbSyncInProgress) return
      this.setIndexingLoadingAcknowledgment(this._indexingWarmCopy("nudge"))
    }, this.constructor.INDEXING_NUDGE_MS)
  }

  clearIndexingNudgeTimer() {
    if (this.indexingNudgeTimer) {
      clearTimeout(this.indexingNudgeTimer)
      this.indexingNudgeTimer = null
    }
  }

  // ── Stall notice while waiting for KbSync `indexed` broadcast ─────────────
  // Backend ingestion can run for a while on large documents: S3 upload, sync
  // page parsing, Bedrock ingestion poll, and metadata enrichment. If the
  // WebSocket dropped mid-flight (Solid Cable does not replay), the dots
  // animation hangs forever until the user reloads. This timer surfaces a
  // recovery hint after the normal long-document window.
  startIndexingStallTimer() {
    this.clearIndexingStallTimer()
    this.indexingStallTimer = setTimeout(() => {
      if (this.pendingUploadType === "document") this.releaseDocumentPinWait()
      this.indexingStallNoticeId = this.addMessage(
        this._indexingWarmCopy("stall"),
        "assistant",
        true  // temporary: removed alongside other temp rows on next removeMessage()
      )
    }, this.constructor.INDEXING_STALL_MS)
  }

  clearIndexingStallTimer() {
    if (this.indexingStallTimer) {
      clearTimeout(this.indexingStallTimer)
      this.indexingStallTimer = null
    }
    if (this.indexingStallNoticeId) {
      document.getElementById(this.indexingStallNoticeId)?.remove()
      this.indexingStallNoticeId = null
    }
  }

  startQueryWaitTimers(loadingId) {
    this.clearQueryNudgeTimer()
    this.clearQueryStallTimer()
    this.queryNudgeTimer = setTimeout(() => {
      if (!document.getElementById(loadingId)) return
      const row    = document.getElementById(loadingId)
      const bubble = row?.querySelector(".chat-message")
      if (!bubble) return
      bubble.innerHTML =
        `<div style="display:flex;flex-direction:column;gap:6px;" role="status" aria-live="polite">` +
        this.constructor.INDEXING_TYPING_DOTS_HTML +
        `<span style="font-size:13px;line-height:1.45;">${this.escapeHtml(this._queryWarmCopy("nudge"))}</span>` +
        `</div>`
    }, this.constructor.CHAT_WARM_NUDGE_MS)

    this.queryStallTimer = setTimeout(() => {
      if (!document.getElementById(loadingId)) return
      this.queryStallNoticeId = this.addMessage(this._queryWarmCopy("stall"), "assistant", true)
    }, this.constructor.CHAT_STALL_HINT_MS)
  }

  clearQueryNudgeTimer() {
    if (this.queryNudgeTimer) {
      clearTimeout(this.queryNudgeTimer)
      this.queryNudgeTimer = null
    }
  }

  clearQueryStallTimer() {
    if (this.queryStallTimer) {
      clearTimeout(this.queryStallTimer)
      this.queryStallTimer = null
    }
    if (this.queryStallNoticeId) {
      document.getElementById(this.queryStallNoticeId)?.remove()
      this.queryStallNoticeId = null
    }
  }

  addIndexedMessage(data) {
    const row = this._buildMessageRow("assistant")
    const bubble = row.querySelector(".chat-message")

    const canonical     = data.canonical_name || (data.filenames && data.filenames[0]) || "Documento"
    const aliases       = Array.isArray(data.aliases) && data.aliases.length ? data.aliases : null
    const partialPages  = Array.isArray(data.partial_pages) ? data.partial_pages.filter(p => p != null) : []
    const selectedPages = Array.isArray(data.selected_pages) ? data.selected_pages.filter(p => p != null) : []
    const isUrgentPages = data.processing_scope === "urgent_pages"
    const lang          = this.localeValue
    const readyLine     = isUrgentPages
      ? (lang.startsWith("en")
        ? "Urgent pages are ready. The full manual is still indexing."
        : "Páginas urgentes listas. El manual completo sigue indexándose.")
      : lang.startsWith("en")
      ? "Ready — you can ask me anything about this."
      : "Listo, ya puedes preguntarme lo que necesites sobre esto."

    let html = `<div style="font-weight:600;">${this.escapeHtml(canonical)}</div>`
    if (isUrgentPages && selectedPages.length > 0) {
      const pagesText = lang.startsWith("en")
        ? `Pages now available: ${selectedPages.join(", ")}`
        : `Páginas disponibles ahora: ${selectedPages.join(", ")}`
      html += `<div style="margin-top:4px;color:#4a5568;font-size:13px;">${this.escapeHtml(pagesText)}</div>`
    }
    if (aliases) {
      const pills = aliases.map(a =>
        `<span style="display:inline-block;background:#e2e8f0;border-radius:9999px;padding:1px 8px;font-size:11px;margin:2px 2px 0 0;color:#4a5568;">${this.escapeHtml(a)}</span>`
      ).join("")
      html += `<div style="margin-top:4px;">${pills}</div>`
    }
    html += `<div style="margin-top:6px;">${this.escapeHtml(readyLine)}</div>`

    if (partialPages.length > 0) {
      const warningText = lang.startsWith("en")
        ? `⚠️ Pages ${partialPages.join(", ")} could not be fully extracted. Re-upload the file to reprocess them.`
        : `⚠️ Las páginas ${partialPages.join(", ")} no se procesaron completamente. Vuelve a subir el archivo para reprocesarlas.`
      html += `<div style="margin-top:6px;color:#b45309;font-size:13px;">${this.escapeHtml(warningText)}</div>`
    }

    bubble.innerHTML = html
    this.messagesTarget.appendChild(row)
    this.scrollToMessageTop(row)
  }

  // Photo without a question: the vision reading in prose, the invitation to
  // ask, and the photo button. Metadata (UNKNOWN, aliases) is not shown.
  addImageSummaryMessage(data) {
    const row = this._buildMessageRow("assistant")
    const bubble = row.querySelector(".chat-message")
    const lang = this.localeValue

    const canonical = String(data.canonical_name || "").trim()
    const inviteFallback = lang.startsWith("en")
      ? "Tell me what you need — you can ask in just a word or two, that\u2019s fine."
      : "Cu\u00e9ntame qu\u00e9 necesitas, puedo ayudarte aunque me preguntes con pocas palabras."
    const invite = (data.companion_offer && data.companion_offer.trim())
      ? data.companion_offer.trim()
      : inviteFallback

    let html = ""
    if (canonical && canonical.toUpperCase() !== "UNKNOWN") {
      html += `<div style="font-weight:600;">${this.escapeHtml(canonical)}</div>`
    }
    if (data.summary) {
      html += `<div style="margin-top:10px;line-height:1.55;">${formatAnswerForWeb(data.summary)}</div>`
    }
    html += `<div style="margin-top:10px;color:#4a5568;">${this.escapeHtml(invite)}</div>`
    html += this._photoReuseRowHtml(data)

    bubble.innerHTML = html
    this.messagesTarget.appendChild(row)
    this.scrollToMessageTop(row)
  }

  // Photo with a question: the single answer of the turn (CG-D19). The photo
  // reading opens the prose the backend generated; there is no separate card.
  // `visual_summary` arrives only when the manuals could not be consulted.
  addPhotoQuestionAnswer(data) {
    const lang = this.localeValue
    const citations = Array.isArray(data.citations) ? data.citations : []
    let html = ""
    if (data.visual_summary) {
      html += `<div data-photo-visual-summary style="line-height:1.55;margin-bottom:10px;">${formatAnswerForWeb(data.visual_summary)}</div>`
    }
    html += `<div style="line-height:1.55;">${formatAnswerForWeb(data.answer, citations, data.provenance_segments)}</div>`
    if (this.showSourcesValue && citations.length) html += renderSources(citations, lang)
    html += renderVerificationNotice(lang)
    html += this._photoReuseRowHtml(data)
    this.addMessageHtml(html, "assistant")
  }

  // Thumbnail plus the "ask about this photo" button, shared by both photo
  // bubbles. Empty when the photo was not persisted.
  _photoReuseRowHtml(data) {
    if (!data.field_photo_id) return ""

    const lang = this.localeValue
    const reuseLabel = lang.startsWith("en") ? "Ask about this photo" : "Preguntar sobre esta foto"
    const viewAria = lang.startsWith("en") ? "Open full photo in a new tab" : "Abrir foto completa en una pestaña nueva"
    const photoUrl = `/field_photos/${encodeURIComponent(data.field_photo_id)}`
    const thumb = data.thumbnail_url
      ? `<a href="${photoUrl}" target="_blank" rel="noopener" aria-label="${this.escapeHtml(viewAria)}"
            style="display:flex;height:44px;width:44px;flex-shrink:0;align-items:center;justify-content:center;border-radius:10px;overflow:hidden;background:#e2e8f0;">
            <img src="${this.escapeHtml(data.thumbnail_url)}" alt="" style="height:100%;width:100%;object-fit:cover;">
          </a>`
      : ""
    return `<div style="margin-top:12px;display:flex;align-items:center;gap:10px;">` +
      thumb +
      `<button type="button"
                data-action="click->rag-chat#reuseFieldPhoto"
                data-field-photo-id="${this.escapeHtml(String(data.field_photo_id))}"
                style="min-height:44px;flex:1;border-radius:10px;border:2px solid #2b6cb0;background:#ffffff;color:#2b6cb0;font-weight:600;font-size:13px;padding:0 14px;">
                ${this.escapeHtml(reuseLabel)}
              </button>` +
      `</div>`
  }

  // Attaches the last analyzed field photo to the next question so a
  // technician can re-ask without re-uploading. Zero bytes leave the device;
  // the backend rehydrates from field_photos/ storage when needed.
  reuseFieldPhoto(event) {
    this.pendingFieldPhotoId = event.currentTarget.dataset.fieldPhotoId
    const lang = this.localeValue
    const attachedLabel = lang.startsWith("en") ? "Photo attached — ask your question" : "Foto adjunta — escribe tu pregunta"
    this.inputTarget.placeholder = attachedLabel
    this.inputTarget.focus()
  }

  async refreshDocuments() {
    if (window.location.pathname !== '/' && window.location.pathname !== '/home') return

    try {
      const response = await fetch('/home/documents', {
        method: 'GET',
        headers: {
          'Accept': 'text/vnd.turbo-stream.html',
          'X-CSRF-Token': document.querySelector('meta[name=csrf-token]')?.content
        },
        credentials: 'same-origin'
      })
      if (!response.ok) return

      const html = await response.text()
      const parser = new DOMParser()
      const doc = parser.parseFromString(html, 'text/html')
      const streams = doc.querySelectorAll('turbo-stream')
      streams.forEach(stream => {
        const clone = stream.cloneNode(true)
        document.body.appendChild(clone)
        setTimeout(() => clone.remove(), 100)
      })

      requestAnimationFrame(() => {
        this.hasArchivosPanelTarget && this.archivosPanelTarget.scrollTo({ top: 0 })
        document
          .querySelector("#kb-docs-desktop-items")
          ?.closest(".overflow-y-auto")
          ?.scrollTo({ top: 0 })
        this.updateSourcesBadge()
      })
    } catch (error) {
      console.error('Error refreshing documents:', error)
    }
  }

}
