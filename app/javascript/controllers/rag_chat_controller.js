// app/javascript/controllers/rag_chat_controller.js

import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { renderReferences } from "rag/references_renderer"
import { renderDocumentsConsulted } from "rag/documents_consulted_renderer"
import { formatAnswerForWeb } from "rag/answer_presenter"

export default class extends Controller {
  static targets = ["input", "sendButton", "messages", "chatContainer", "fileInput", "filePreview", "imageThumb", "docIcon", "fileName"]

  static MAX_IMAGE_SIZE = 3.75 * 1024 * 1024  // 3.75 MB (Bedrock KB limit for images)
  static MAX_DOC_SIZE = 50 * 1024 * 1024     // 50 MB (Bedrock KB limit for documents)
  static SUPPORTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]
  static SUPPORTED_DOC_TYPES = ["text/plain", "text/markdown", "text/html", "text/csv", "application/pdf", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/msword", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-excel"]
  static DOC_EXTENSIONS = [".txt", ".md", ".html", ".csv", ".pdf", ".doc", ".docx", ".xls", ".xlsx"]
  static BINARY_DOC_EXTENSIONS = [".pdf", ".doc", ".docx", ".xls", ".xlsx"]

  connect() {
    this.pendingFile = null
    this.pendingImageQuery = null
    this.metricsRefreshTimers = []
    this.subscribeToKbSync()
    this.inputTarget?.focus()
  }

  disconnect() {
    this.kbSyncSubscription?.unsubscribe()
    this.clearMetricsRefreshTimers()
  }

  clearMetricsRefreshTimers() {
    (this.metricsRefreshTimers || []).forEach((id) => clearTimeout(id))
    this.metricsRefreshTimers = []
  }

  /**
   * TrackBedrockQueryJob runs async (perform_later); metrics are not in DB until it finishes.
   * In dev, Cable often runs in the web process while jobs run in a separate worker, so Turbo
   * broadcasts from the job may never reach the browser — poll /home/metrics a few times.
   */
  scheduleMetricsRefresh() {
    this.clearMetricsRefreshTimers()
    this.updateMetrics()
    const delays = [400, 1200, 3000, 7000]
    delays.forEach((ms) => {
      this.metricsRefreshTimers.push(setTimeout(() => this.updateMetrics(), ms))
    })
  }

  subscribeToKbSync() {
    if (window.location.pathname !== "/" && window.location.pathname !== "/home") return

    const controller = this
    const consumer = createConsumer()
    this.kbSyncSubscription = consumer.subscriptions.create("KbSyncChannel", {
      received(data) {
        if (data.status === "indexed" || data.status === "failed") {
          controller.refreshDocuments()
          if (data.message) {
            const type = data.status === "indexed" ? "system" : "error"
            controller.addMessage(data.message, type)
          }

          if (data.status === "indexed" && controller.pendingImageQuery) {
            const query = controller.pendingImageQuery
            controller.pendingImageQuery = null
            controller.sendTextQuery(query)
          } else if (data.status === "failed") {
            controller.pendingImageQuery = null
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
      this.addMessage("Formato no soportado. Imágenes: JPEG o PNG (máx. 3.75 MB). Documentos: .txt, .md, .html, .csv, .pdf, .doc, .docx, .xls, .xlsx (máx. 50 MB).", "error")
      this.fileInputTarget.value = ""
      return
    }

    const maxSize = isImage ? this.constructor.MAX_IMAGE_SIZE : this.constructor.MAX_DOC_SIZE
    const maxLabel = isImage ? "3.75 MB" : "50 MB"
    if (file.size > maxSize) {
      const msg = isImage
        ? "La imagen excede el límite de 3.75 MB (Knowledge Base). Comprímela o reduce su tamaño."
        : "El documento excede el límite de 50 MB."
      this.addMessage(msg, "error")
      this.fileInputTarget.value = ""
      return
    }

    if (isImage) {
      const reader = new FileReader()
      reader.onload = (e) => {
        this.compressImageOnClient(e.target.result).then(({ base64, dataUrl }) => {
          this.pendingFile = { data: base64, media_type: "image/jpeg", filename: file.name, type: "image" }
          this.showPreview(dataUrl, file.name, "image")
        }).catch(() => {
          // Fallback: send as-is if Canvas fails (e.g. cross-origin taint)
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
          this.fileInputTarget.value = ""
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
      xls: "application/vnd.ms-excel", xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
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
  // Returns { base64: string, dataUrl: string }.
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
            resolve({ base64: resultDataUrl.split(",")[1], dataUrl: resultDataUrl })
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

      if (data.images_uploaded?.length) {
        this.addMessage(data.answer, "system")
        if (question) this.pendingImageQuery = question
        this.refreshDocuments()
      } else if (data.documents_uploaded?.length) {
        this.addMessage(data.answer, "system")
        this.refreshDocuments()
        [ 2000, 5000 ].forEach(ms => setTimeout(() => this.refreshDocuments(), ms))
      } else {
        const citations = Array.isArray(data.citations) ? data.citations : []
        if (citations.length) {
          this.addMessageHtml(renderDocumentsConsulted(citations), "assistant")
        }
        const answerHtml = formatAnswerForWeb(data.answer, citations)
        this.addMessageHtml(answerHtml, "assistant")
        if (citations.length) {
          this.addMessageHtml(renderReferences(citations), "assistant")
        }
      }

      this.scheduleMetricsRefresh()
    } catch (error) {
      this.removeMessage(loadingId)
      this.addMessage(`Error: ${error.message}`, "error")
    } finally {
      this.enableForm()
    }
  }

  async sendTextQuery(question) {
    this.disableForm()
    const loadingId = this.addMessage("Thinking…", "assistant", true)

    try {
      const data = await this.ask(question, null)
      this.removeMessage(loadingId)

      if (data.status !== "success") {
        throw new Error(data.message || "Unknown error")
      }

      const citations = Array.isArray(data.citations) ? data.citations : []
      if (citations.length) {
        this.addMessageHtml(renderDocumentsConsulted(citations), "assistant")
      }
      const answerHtml = formatAnswerForWeb(data.answer, citations)
      this.addMessageHtml(answerHtml, "assistant")
      if (citations.length) {
        this.addMessageHtml(renderReferences(citations), "assistant")
      }
      this.scheduleMetricsRefresh()
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
        payload.image = { data: file.data, media_type: file.media_type, filename: file.filename }
      } else {
        payload.document = { data: file.data, media_type: file.media_type, filename: file.filename }
      }
    }
    const response = await fetch("/rag/ask", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Accept-Language": document.documentElement.lang || navigator.language || "es",
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
