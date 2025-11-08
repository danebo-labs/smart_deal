import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container"]
  static values = {
    lineDelay: { type: Number, default: 110 }
  }

  connect() {
    if (!this.hasContainerTarget) return

    const html = this.containerTarget.innerHTML.trim()
    if (!html) return

    const wrapper = document.createElement("div")
    wrapper.innerHTML = html

    const nodes = Array.from(wrapper.childNodes).filter((node) => {
      if (node.nodeType === Node.TEXT_NODE) {
        return node.textContent.trim() !== ""
      }
      return true
    })

    if (nodes.length === 0) return

    this.lines = nodes.map((node) => this.prepareNode(node))
    this.containerTarget.innerHTML = ""
    this.timeouts = []
    this.index = 0
    this.revealNext()
  }

  disconnect() {
    if (this.timeouts) {
      this.timeouts.forEach((timeoutId) => clearTimeout(timeoutId))
    }
  }

  prepareNode(node) {
    let element
    if (node.nodeType === Node.ELEMENT_NODE) {
      element = node
    } else {
      element = document.createElement("p")
      element.textContent = node.textContent
    }

    element.classList.add("ai-line")
    return element
  }

  revealNext() {
    if (this.index >= this.lines.length) return

    const line = this.lines[this.index]
    this.containerTarget.appendChild(line)

    requestAnimationFrame(() => {
      line.classList.add("is-visible")
      this.scrollToBottom()
    })

    this.index += 1
    if (this.index < this.lines.length) {
      const delay = Math.max(45, this.lineDelayValue)
      const timeoutId = setTimeout(() => this.revealNext(), delay)
      this.timeouts.push(timeoutId)
    }
  }

  scrollToBottom() {
    this.containerTarget.scrollTop = this.containerTarget.scrollHeight
  }
}
