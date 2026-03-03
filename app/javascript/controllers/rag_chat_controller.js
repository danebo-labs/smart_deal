// app/javascript/controllers/rag_chat_controller.js

import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { formatAnswer } from "rag/citation_formatter"
import { renderReferences } from "rag/references_renderer"

export default class extends Controller {
  static targets = ["input", "sendButton", "messages", "chatContainer", "fileInput", "filePreview", "imageThumb", "docIcon", "fileName", "modelSelect"]

  static MAX_IMAGE_SIZE = 3.75 * 1024 * 1024
  static MAX_DOC_SIZE = 10 * 1024 * 1024 // 10 MB (Bedrock KB limit is 50 MB)
  static SUPPORTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]
  static SUPPORTED_DOC_TYPES = ["text/plain", "text/markdown", "text/html", "text/csv"]
  static DOC_EXTENSIONS = [".txt", ".md", ".html", ".csv"]

  connect() {
    this.pendingFile = null
    this.subscribeToKbSync()
    this.inputTarget?.focus()
  }

  disconnect() {
    this.kbSyncSubscription?.unsubscribe()
  }

  subscribeToKbSync() {
    if (window.location.pathname !== "/" && window.location.pathname !== "/home") return

    const controller = this
    const consumer = createConsumer()
    this.kbSyncSubscription = consumer.subscriptions.create("KbSyncChannel", {
      received(data) {
        if (data.status === "indexed" || data.status === "failed") {
          controller.refreshDocuments()
          if (data.status === "failed" && data.message) {
            controller.addMessage(data.message, "error")
          }
        }
      }
    })
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
      this.addMessage("Solo se permiten imágenes (PNG, JPEG, GIF, WebP) o documentos (.txt, .md, .html, .csv).", "error")
      this.fileInputTarget.value = ""
      return
    }

    const maxSize = isImage ? this.constructor.MAX_IMAGE_SIZE : this.constructor.MAX_DOC_SIZE
    const maxLabel = isImage ? "3.75 MB" : "10 MB"
    if (file.size > maxSize) {
      this.addMessage(`El archivo excede el límite de ${maxLabel}.`, "error")
      this.fileInputTarget.value = ""
      return
    }

    if (isImage) {
      const reader = new FileReader()
      reader.onload = (e) => {
        const base64Full = e.target.result
        const base64Data = base64Full.split(",")[1]
        this.pendingFile = { data: base64Data, media_type: file.type, filename: file.name, type: "image" }
        this.showPreview(base64Full, file.name, "image")
      }
      reader.readAsDataURL(file)
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

  getDocMimeType(filename, fallbackType) {
    const ext = filename.toLowerCase().split(".").pop()
    const map = { txt: "text/plain", md: "text/markdown", html: "text/html", csv: "text/csv" }
    return map[ext] || fallbackType || "text/plain"
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

    const loadingId = this.addMessage("Thinking…", "assistant", true)

    try {
      const data = await this.ask(question, fileToSend)
      this.removeMessage(loadingId)

      if (data.status !== "success") {
        throw new Error(data.message || "Unknown error")
      }

      if (data.documents_uploaded?.length) {
        this.addMessage(data.answer, "system")
        this.refreshDocuments()
        setTimeout(() => this.refreshDocuments(), 2000)
      } else {
        const answerHtml = formatAnswer(data.answer, data.citations)
        this.addMessageHtml(answerHtml, "assistant")
        if (data.citations?.length) {
          this.addMessageHtml(renderReferences(data.citations), "assistant")
        }
      }

      this.updateMetrics()
    } catch (error) {
      this.removeMessage(loadingId)
      this.addMessage(`Error: ${error.message}`, "error")
    } finally {
      this.enableForm()
    }
  }

  async ask(question, file = null) {
    const payload = { question }
    if (file) {
      if (file.type === "image") {
        payload.image = { data: file.data, media_type: file.media_type }
      } else {
        payload.document = { data: file.data, media_type: file.media_type, filename: file.filename }
      }
    }
    if (this.hasModelSelectTarget && this.modelSelectTarget.value) {
      payload.model = this.modelSelectTarget.value
    }

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

  addDocumentMessage(filename, text) {
    const div = document.createElement("div")
    div.className = "chat-message chat-message-user"

    let html = `<span style="font-size: 12px; color: #4a5568;">📄 ${this.escapeHtml(filename)}</span>`
    if (text) html += `<br><span>${this.escapeHtml(text)}</span>`

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
    } catch (error) {
      console.error('Error refreshing documents:', error)
    }
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
