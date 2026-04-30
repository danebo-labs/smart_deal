import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { delay: { type: Number, default: 3000 } }

  connect() {
    setTimeout(() => this.#dismiss(), this.delayValue)
  }

  #dismiss() {
    this.element.style.transition = "opacity 0.35s ease, transform 0.35s ease"
    this.element.style.opacity = "0"
    this.element.style.transform = "translateY(-3px)"
    setTimeout(() => this.element.remove(), 350)
  }
}
