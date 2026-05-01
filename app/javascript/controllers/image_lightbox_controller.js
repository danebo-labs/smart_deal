// app/javascript/controllers/image_lightbox_controller.js
import { Controller } from "@hotwired/stimulus"

const OVERLAY_ID    = "image-lightbox-overlay"
const SWIPE_DISMISS = 80 // px vertical drag → close

export default class extends Controller {
  static values = {
    fullUrl:  String,
    thumbUrl: String,
    name:     String
  }

  open(event) {
    event?.preventDefault?.()
    const overlay = this.constructor.ensureOverlay()

    overlay._lastFocus = document.activeElement
    overlay._opener    = this.element

    const img = overlay.querySelector("[data-lightbox-img]")
    const cap = overlay.querySelector("[data-lightbox-caption]")

    img.classList.add("is-loading")
    img.removeAttribute("data-loaded")
    img.src = this.thumbUrlValue || ""
    cap.textContent = this.nameValue || ""

    if (this.fullUrlValue) {
      const preload = new Image()
      preload.onload = () => {
        if (overlay._currentSrc !== this.fullUrlValue) return
        img.src = this.fullUrlValue
        img.classList.remove("is-loading")
        img.setAttribute("data-loaded", "true")
      }
      preload.onerror = () => {
        img.classList.remove("is-loading")
        cap.textContent = `${this.nameValue || ""} — error al cargar`
      }
      overlay._currentSrc = this.fullUrlValue
      preload.src = this.fullUrlValue
    } else {
      img.classList.remove("is-loading")
    }

    overlay.classList.remove("hidden")
    overlay.setAttribute("aria-hidden", "false")
    document.body.style.overflow = "hidden"

    if (!history.state || !history.state.imageLightbox) {
      history.pushState({ imageLightbox: true }, "")
    }
    overlay._closeBtn.focus()
  }

  // ── Singleton overlay management ─────────────────────────────────────────

  static ensureOverlay() {
    let overlay = document.getElementById(OVERLAY_ID)
    if (overlay) return overlay

    overlay = document.createElement("div")
    overlay.id = OVERLAY_ID
    overlay.className = "image-lightbox-overlay hidden"
    overlay.setAttribute("role", "dialog")
    overlay.setAttribute("aria-modal", "true")
    overlay.setAttribute("aria-label", "Vista ampliada")
    overlay.setAttribute("aria-hidden", "true")
    overlay.innerHTML = `
      <div class="image-lightbox-backdrop" data-lightbox-backdrop></div>
      <div class="image-lightbox-stage" data-lightbox-stage>
        <img data-lightbox-img alt="" />
        <div class="image-lightbox-caption" data-lightbox-caption></div>
        <button type="button"
                class="image-lightbox-close"
                data-lightbox-close
                aria-label="Cerrar">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <line x1="6" y1="6" x2="18" y2="18"/>
            <line x1="18" y1="6" x2="6" y2="18"/>
          </svg>
        </button>
      </div>
    `
    document.body.appendChild(overlay)

    overlay._closeBtn = overlay.querySelector("[data-lightbox-close]")
    overlay._backdrop = overlay.querySelector("[data-lightbox-backdrop]")
    overlay._stage    = overlay.querySelector("[data-lightbox-stage]")

    const close = () => this.closeOverlay(overlay)

    overlay._closeBtn.addEventListener("click", close)
    overlay._backdrop.addEventListener("click", close)

    document.addEventListener("keydown", (e) => {
      if (overlay.classList.contains("hidden")) return
      if (e.key === "Escape") { e.preventDefault(); close() }
      if (e.key === "Tab")    { e.preventDefault(); overlay._closeBtn.focus() } // simple focus trap
    })

    window.addEventListener("popstate", () => {
      if (!overlay.classList.contains("hidden")) this.closeOverlay(overlay, { skipHistory: true })
    })

    // Swipe-down to dismiss (mobile)
    let startY = null
    overlay._stage.addEventListener("touchstart", (e) => {
      startY = e.touches[0]?.clientY ?? null
    }, { passive: true })
    overlay._stage.addEventListener("touchend", (e) => {
      if (startY == null) return
      const endY = e.changedTouches[0]?.clientY ?? startY
      if (endY - startY > SWIPE_DISMISS) close()
      startY = null
    }, { passive: true })

    return overlay
  }

  static closeOverlay(overlay, { skipHistory = false } = {}) {
    overlay.classList.add("hidden")
    overlay.setAttribute("aria-hidden", "true")
    document.body.style.overflow = ""
    overlay._currentSrc = null

    if (!skipHistory && history.state && history.state.imageLightbox) {
      history.back()
    }
    overlay._lastFocus?.focus?.()
    overlay._lastFocus = null
    overlay._opener    = null
  }
}
