// app/javascript/controllers/rag_chat_controller.js

import { Controller } from "@hotwired/stimulus"
import { formatAnswer } from "rag/citation_formatter"
import { renderReferences } from "rag/references_renderer"

export default class extends Controller {
  static targets = ["input", "sendButton", "messages", "chatContainer", "fileInput", "imagePreview", "imageThumb", "imageName"]

  static MAX_IMAGE_SIZE = 3.75 * 1024 * 1024
  static SUPPORTED_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]

  connect() {
    this.pendingImage = null
    this.inputTarget?.focus()
  }

  clickAttach() {
    this.fileInputTarget.click()
  }

  selectImage(event) {
    const file = event.target.files[0]
    if (!file) return

    if (!this.constructor.SUPPORTED_TYPES.includes(file.type)) {
      this.addMessage("Solo se permiten imágenes PNG, JPEG, GIF o WebP.", "error")
      this.fileInputTarget.value = ""
      return
    }

    if (file.size > this.constructor.MAX_IMAGE_SIZE) {
      this.addMessage("La imagen excede el límite de 3.75 MB.", "error")
      this.fileInputTarget.value = ""
      return
    }

    const reader = new FileReader()
    reader.onload = (e) => {
      const base64Full = e.target.result
      const base64Data = base64Full.split(",")[1]

      this.pendingImage = { data: base64Data, media_type: file.type }

      this.imageThumbTarget.src = base64Full
      this.imageNameTarget.textContent = file.name
      this.imagePreviewTarget.style.display = "block"
    }
    reader.readAsDataURL(file)
  }

  removeImage() {
    this.pendingImage = null
    this.fileInputTarget.value = ""
    this.imagePreviewTarget.style.display = "none"
  }

  async sendMessage(event) {
    event.preventDefault()

    const question = this.inputTarget.value.trim()
    const hasImage = this.pendingImage !== null

    if (!question && !hasImage) return

    this.disableForm()

    if (hasImage) {
      this.addImageMessage(this.imageThumbTarget.src, question)
    } else {
      this.addMessage(question, "user")
    }

    this.inputTarget.value = ""
    const imageToSend = this.pendingImage
    this.removeImage()

    const loadingId = this.addMessage("Thinking…", "assistant", true)

    try {
      const data = await this.ask(question, imageToSend)
      this.removeMessage(loadingId)

      if (data.status !== "success") {
        throw new Error(data.message || "Unknown error")
      }

      const answerHtml = formatAnswer(data.answer, data.citations)
      this.addMessageHtml(answerHtml, "assistant")

      if (data.citations?.length) {
        this.addMessageHtml(renderReferences(data.citations), "assistant")
      }

      this.updateMetrics()
    } catch (error) {
      this.removeMessage(loadingId)
      this.addMessage(`Error: ${error.message}`, "error")
    } finally {
      this.enableForm()
    }
  }

  async ask(question, image = null) {
    const payload = { question }
    if (image) payload.image = image

    const response = await fetch("/rag/ask", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
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
    this.inputTarget.focus()
  }

  addMessage(text, type, temporary = false) {
    const id = `msg-${Date.now()}`
    const div = document.createElement("div")

    div.id = id
    div.className = `chat-message chat-message-${type}`
    if (temporary) div.dataset.temporary = true

    div.textContent = text
    this.messagesTarget.appendChild(div)
    this.scroll()

    return id
  }

  addImageMessage(imageSrc, text) {
    const div = document.createElement("div")
    div.className = "chat-message chat-message-user"

    let html = `<img src="${imageSrc}" style="max-width: 200px; max-height: 150px; border-radius: 8px; display: block; margin-bottom: 4px;" />`
    if (text) html += `<span>${this.escapeHtml(text)}</span>`

    div.innerHTML = html
    this.messagesTarget.appendChild(div)
    this.scroll()
  }

  addMessageHtml(html, type) {
    const div = document.createElement("div")
    div.className = `chat-message chat-message-${type}`
    div.innerHTML = html
    this.messagesTarget.appendChild(div)
    this.scroll()
  }

  removeMessage(id) {
    document.getElementById(id)?.remove()
    this.messagesTarget
      .querySelectorAll("[data-temporary]")
      .forEach(el => el.remove())
  }

  scroll() {
    this.chatContainerTarget.scrollTop =
      this.chatContainerTarget.scrollHeight
  }

  handleKeyPress(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.sendMessage(event)
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  async updateMetrics() {
    // Only update if we're on the home page
    if (window.location.pathname !== '/' && window.location.pathname !== '/home') {
      return
    }

    try {
      const response = await fetch('/home/metrics', {
        method: 'GET',
        headers: {
          'Accept': 'text/vnd.turbo-stream.html',
          'X-CSRF-Token': document.querySelector('meta[name=csrf-token]')?.content
        },
        credentials: 'same-origin'
      })

      if (!response.ok) return

      // Turbo automatically processes streams when added to DOM
      const html = await response.text()
      const parser = new DOMParser()
      const doc = parser.parseFromString(html, 'text/html')
      const streams = doc.querySelectorAll('turbo-stream')

      streams.forEach(stream => {
        const clone = stream.cloneNode(true)
        document.body.appendChild(clone)
        // Turbo processes synchronously, remove after a brief delay
        setTimeout(() => clone.remove(), 100)
      })
    } catch (error) {
      // Silently fail - metrics update is not critical
      console.error('Error updating metrics:', error)
    }
  }
}
