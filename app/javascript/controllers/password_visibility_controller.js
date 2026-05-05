import { Controller } from "@hotwired/stimulus"

// Toggle password field type; updates icons and aria for screen readers / voice control.
export default class extends Controller {
  static targets = ["input", "button", "showIcon", "hideIcon"]
  static values = {
    showLabel: { type: String, default: "Mostrar contraseña" },
    hideLabel: { type: String, default: "Ocultar contraseña" }
  }

  connect() {
    this.sync()
  }

  toggle(event) {
    event.preventDefault()
    const reveal = this.inputTarget.type === "password"
    this.inputTarget.type = reveal ? "text" : "password"
    this.sync()
  }

  sync() {
    const concealed = this.inputTarget.type === "password"
    this.showIconTarget.classList.toggle("hidden", !concealed)
    this.hideIconTarget.classList.toggle("hidden", concealed)
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-pressed", (!concealed).toString())
      this.buttonTarget.setAttribute(
        "aria-label",
        concealed ? this.showLabelValue : this.hideLabelValue
      )
    }
  }
}
