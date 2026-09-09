import { Controller } from "@hotwired/stimulus"

// Debounced autosave of a dictation's correction (Fase 5, fixed rule 11):
// reloading or closing the page never loses an edit the certifier has not
// confirmed yet. Correction is a one-step act — edit the text in place, never
// re-record (plan section 2.3, Google confirmation guideline).
//
// Attached to the confirm form. The form itself carries the textarea, so a
// confirm tap inside the debounce window still commits what is on screen; on
// submit the pending save is simply dropped. A 409 means the dictation is no
// longer editable (already confirmed) and stops the retries.
const DEBOUNCE_MS = 800
const RETRY_MS = 5000
const MAX_RETRIES = 3

export default class extends Controller {
  static targets = ["field", "status"]
  static values = { url: String, labels: Object }

  connect() {
    this.dirty = false
    this.retries = 0
    this.lastSaved = this.fieldTarget.value

    this.onSubmit = () => this.#cancelPending()
    this.onOnline = () => { if (this.dirty) this.#save() }
    this.onPageHide = () => this.#flush()
    this.element.addEventListener("submit", this.onSubmit)
    window.addEventListener("online", this.onOnline)
    window.addEventListener("pagehide", this.onPageHide)
  }

  disconnect() {
    this.element.removeEventListener("submit", this.onSubmit)
    window.removeEventListener("online", this.onOnline)
    window.removeEventListener("pagehide", this.onPageHide)
    this.#flush()
  }

  changed() {
    this.dirty = this.fieldTarget.value !== this.lastSaved
    if (!this.dirty) return

    this.retries = 0
    this.#setStatus(this.labelsValue.saving)
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.#save(), DEBOUNCE_MS)
  }

  async #save() {
    clearTimeout(this.timer)
    if (!this.dirty) return

    const text = this.fieldTarget.value
    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: this.#headers(),
        credentials: "same-origin",
        body: this.#body(text)
      })

      if (response.status === 409) {
        this.dirty = false
        this.#setStatus(this.labelsValue.frozen)
        return
      }
      if (!response.ok) throw new Error(`autosave failed: ${response.status}`)

      this.lastSaved = text
      this.dirty = this.fieldTarget.value !== text
      this.#setStatus(this.labelsValue.saved)
      // Typed more while the request was in flight: save that too.
      if (this.dirty) this.timer = setTimeout(() => this.#save(), DEBOUNCE_MS)
    } catch (error) {
      console.warn("transcript-autosave: not saved yet", error)
      this.#setStatus(this.labelsValue.failed)
      if (this.retries < MAX_RETRIES) {
        this.retries += 1
        this.timer = setTimeout(() => this.#save(), RETRY_MS)
      }
      // Past the retry budget it waits for the next keystroke or the `online`
      // event, and the form submit still carries the text.
    }
  }

  // Last chance on navigation/unload: keepalive lets the request outlive the
  // page. Best effort, no status update — there is no page left to show it.
  #flush() {
    clearTimeout(this.timer)
    if (!this.dirty) return

    const text = this.fieldTarget.value
    this.dirty = false
    try {
      fetch(this.urlValue, {
        method: "PATCH",
        headers: this.#headers(),
        credentials: "same-origin",
        keepalive: true,
        body: this.#body(text)
      }).catch(() => {})
    } catch (_error) {
      // keepalive unsupported or body too large: nothing more to do here.
    }
  }

  #cancelPending() {
    clearTimeout(this.timer)
    this.dirty = false
  }

  #headers() {
    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
    }
  }

  #body(text) {
    return JSON.stringify({ voice_dictation: { transcript_edited: text } })
  }

  #setStatus(label) {
    if (this.hasStatusTarget) this.statusTarget.textContent = label
  }
}
