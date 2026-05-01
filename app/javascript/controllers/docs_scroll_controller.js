import { Controller } from "@hotwired/stimulus"

// IntersectionObserver-driven infinite scroll for KB docs lists.
// Element is a 1-pixel sentinel placed after the last row. When it enters the
// viewport, fetch the next page of rows as a Turbo Stream and let Turbo append
// them to the items container. The sentinel is replaced (or removed) by the
// stream, which auto-disconnects this controller and reconnects on the new one.
export default class extends Controller {
  static values = { url: String, page: Number }

  connect() {
    this.loading = false
    this.observer = new IntersectionObserver(
      (entries) => {
        if (entries.some(e => e.isIntersecting)) this.loadMore()
      },
      { rootMargin: "200px" }
    )
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
  }

  async loadMore() {
    if (this.loading) return
    this.loading = true
    try {
      const resp = await fetch(`${this.urlValue}?page=${this.pageValue}`, {
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
      console.error("docs-scroll: loadMore failed", e)
    } finally {
      this.loading = false
    }
  }
}
