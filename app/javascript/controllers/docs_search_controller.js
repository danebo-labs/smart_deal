import { Controller } from "@hotwired/stimulus"

const DEBOUNCE_MS = 250

// Debounced search box above the KB docs list. Fetches the filtered list as
// a Turbo Stream from HomeController#documents (same action used by
// refreshDocuments) and lets Turbo replace both desktop/mobile lists and
// their sentinels. No client-side state — the server is the source of truth.
export default class extends Controller {
  static values = { url: String }
  static targets = ["input"]

  connect() {
    this.timer = null
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  search() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = setTimeout(() => this.fetchResults(), DEBOUNCE_MS)
  }

  async fetchResults() {
    const q = this.inputTarget.value
    try {
      const resp = await fetch(`${this.urlValue}?q=${encodeURIComponent(q)}`, {
        headers: {
          "Accept":       "text/vnd.turbo-stream.html",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
        },
        credentials: "same-origin"
      })
      if (!resp.ok) return
      const html = await resp.text()
      window.Turbo?.renderStreamMessage(html)
    } catch (e) {
      console.error("docs-search: fetchResults failed", e)
    }
  }
}
