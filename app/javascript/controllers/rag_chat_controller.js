// app/javascript/controllers/rag_chat_controller.js

import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { renderReferences } from "rag/references_renderer"
import { renderDocumentsConsulted } from "rag/documents_consulted_renderer"
import { formatAnswerForWeb } from "rag/answer_presenter"

export default class extends Controller {
  static targets = ["input", "sendButton", "messages", "chatContainer", "fileInput", "filePreview", "imageThumb", "docIcon", "fileName", "inputStack"]

  static MAX_IMAGE_SIZE = 3.75 * 1024 * 1024  // 3.75 MB (Bedrock KB limit for images)
  static MAX_DOC_SIZE = 50 * 1024 * 1024     // 50 MB (Bedrock KB limit for documents)
  static SUPPORTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]
  static SUPPORTED_DOC_TYPES = ["text/plain", "text/markdown", "text/html", "text/csv", "application/pdf", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/msword", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-excel"]
  static DOC_EXTENSIONS = [".txt", ".md", ".html", ".csv", ".pdf", ".doc", ".docx", ".xls", ".xlsx"]
  static BINARY_DOC_EXTENSIONS = [".pdf", ".doc", ".docx", ".xls", ".xlsx"]

  // SVG icons for mobile message avatars
  static USER_SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>`
  static BOT_SVG  = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/></svg>`

  connect() {
    this.pendingFile = null
    this.pendingImageQuery = null
    this.indexingLoadingId = null
    this._docsPanelExpanded = true  // tracks empty-chat state on mobile
    this.subscribeToKbSync()
    this.setupMobileLayout()
    this.setupKeyboardLift()
    // Focus AFTER layout setup; on mobile the browser will not auto-open the
    // keyboard from a programmatic focus without a user gesture, so this is
    // safe and doesn't trigger a layout shift.
    this.inputTarget?.focus()
  }

  disconnect() {
    this.kbSyncSubscription?.unsubscribe()
    this.mobilePanelObserver?.disconnect()
    window.removeEventListener("resize", this._onResize)
    this.teardownKeyboardLift()
  }

  subscribeToKbSync() {
    if (window.location.pathname !== "/" && window.location.pathname !== "/home") return

    const controller = this
    const consumer = createConsumer()
    this.kbSyncSubscription = consumer.subscriptions.create("KbSyncChannel", {
      received(data) {
        if (data.status === "indexed" || data.status === "failed") {
          if (controller.indexingLoadingId) {
            controller.removeMessage(controller.indexingLoadingId)
            controller.indexingLoadingId = null
          }
          controller.refreshDocuments()
          if (data.status === "indexed") {
            controller.addIndexedMessage(data)
          } else if (data.message) {
            controller.addMessage(data.message, "error")
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

    const loadingId = this.addLoadingMessage()

    try {
      const data = await this.ask(question, fileToSend)

      if (data.status !== "success") {
        this.removeMessage(loadingId)
        throw new Error(data.message || "Unknown error")
      }

      // For image/document uploads, KEEP the same dots bubble alive until
      // KbSyncChannel signals "indexed" (or "failed"). No intermediate text
      // bubble is shown — only the typing animation, then the ✅ canonical name.
      if (data.images_uploaded?.length) {
        this.indexingLoadingId = loadingId
        if (question) this.pendingImageQuery = question
        this.refreshDocuments()
      } else if (data.documents_uploaded?.length) {
        this.indexingLoadingId = loadingId
        this.refreshDocuments()
      } else {
        this.removeMessage(loadingId)
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
    } catch (error) {
      this.removeMessage(loadingId)
      this.addMessage(`Error: ${error.message}`, "error")
    } finally {
      this.enableForm()
    }
  }

  async sendTextQuery(question) {
    this.disableForm()
    const loadingId = this.addLoadingMessage()

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

  // ── Mobile layout: expand docs panel when chat is empty ──────────────────

  setupMobileLayout() {
    this.updateMobileLayout()
    this.mobilePanelObserver = new MutationObserver(() => this.updateMobileLayout())
    this.mobilePanelObserver.observe(this.messagesTarget, { childList: true })
    this._onResize = () => this.updateMobileLayout()
    window.addEventListener("resize", this._onResize, { passive: true })
  }

  updateMobileLayout() {
    const docsPanel = this.element.querySelector(".mobile-docs-panel")
    if (!docsPanel) return
    // Only apply on mobile — when md:hidden is active, display is "none"
    if (window.getComputedStyle(docsPanel).display === "none") return

    const hasMessages = this.messagesTarget.children.length > 0
    if (hasMessages) {
      // When transitioning from the expanded (empty-chat) state, reset the
      // docs scroll so the user always sees the top of the list (newest doc).
      if (this._docsPanelExpanded) {
        this._docsPanelExpanded = false
        requestAnimationFrame(() => docsPanel.scrollTo({ top: 0 }))
      }
      // Active chat: docs panel locked to (50svh - 58px) so the WHOLE chat
      // block (messages + file preview + input) takes at most 50% of the
      // small viewport. Both panes stay independently scrollable.
      docsPanel.style.cssText = "flex: 0 0 calc(50svh - 58px); min-height: 0;"
      this.chatContainerTarget.style.cssText = "flex: 1 1 0%; min-height: 0;"
    } else {
      // Empty chat: docs panel fills all available space; messages area collapses
      this._docsPanelExpanded = true
      docsPanel.style.cssText = "flex: 1 1 0%;"
      this.chatContainerTarget.style.cssText = "flex: 0 0 0%; overflow: hidden;"
    }
  }

  // ── Keyboard lift (mobile only) ───────────────────────────────────────────
  // Uses the VisualViewport API to detect the on-screen keyboard and exposes
  // its height as the CSS variable --kbd-h on <html>. CSS in application.css
  // (.chat-input-stack) consumes that variable to translate the input bar up
  // and keep the textarea anchored above the keyboard. The rest of the UI
  // (KB list + chat messages) does NOT move — body height is locked to 100svh.
  setupKeyboardLift() {
    const vv = window.visualViewport
    if (!vv) return  // very old browsers — silently no-op (layout still works)

    this._onVvChange = () => {
      // Keyboard height = layout viewport bottom - visual viewport bottom.
      // Clamp at 0 so non-keyboard resizes (URL bar, rotation) don't lift.
      const layoutH = window.innerHeight
      const visualBottom = vv.height + vv.offsetTop
      const kbdH = Math.max(0, Math.round(layoutH - visualBottom))
      document.documentElement.style.setProperty("--kbd-h", `${kbdH}px`)
    }

    vv.addEventListener("resize", this._onVvChange)
    vv.addEventListener("scroll", this._onVvChange)
    this._onVvChange()
  }

  teardownKeyboardLift() {
    const vv = window.visualViewport
    if (!vv || !this._onVvChange) return
    vv.removeEventListener("resize", this._onVvChange)
    vv.removeEventListener("scroll", this._onVvChange)
    document.documentElement.style.removeProperty("--kbd-h")
    this._onVvChange = null
  }

  // ── Message row builder (avatar + bubble wrapper) ─────────────────────────
  // Each message is wrapped in a flex row:
  //   user      → flex-row-reverse (avatar right, bubble left, both pushed right)
  //   assistant → flex-row (avatar left, bubble right)
  //   system    → centered, no avatar

  _buildMessageRow(type, id = null, temporary = false) {
    const isUser   = type === "user"
    const isSystem = type === "system"

    const row = document.createElement("div")
    row.className = `chat-row chat-row-${isUser ? "user" : isSystem ? "system" : "assistant"}`
    if (id) row.id = id
    if (temporary) row.dataset.temporary = true

    if (!isSystem) {
      const avatar = document.createElement("div")
      avatar.className = `chat-avatar ${isUser ? "chat-avatar-user" : "chat-avatar-bot"}`
      avatar.innerHTML = isUser ? this.constructor.USER_SVG : this.constructor.BOT_SVG
      row.appendChild(avatar)
    }

    const bubble = document.createElement("div")
    bubble.className = `chat-message chat-message-${type}`
    row.appendChild(bubble)

    return row
  }

  addLoadingMessage() {
    const id  = `msg-${Date.now()}`
    const row = this._buildMessageRow("assistant", id, true)
    row.querySelector(".chat-message").innerHTML =
      `<span style="display:inline-flex;gap:5px;align-items:center;padding:2px 0;">` +
      `<span class="chat-typing-dot"></span>` +
      `<span class="chat-typing-dot"></span>` +
      `<span class="chat-typing-dot"></span>` +
      `</span>`
    this.messagesTarget.appendChild(row)
    this.scroll()
    return id
  }

  addMessage(text, type, temporary = false) {
    const id  = `msg-${Date.now()}`
    const row = this._buildMessageRow(type, id, temporary)
    row.querySelector(".chat-message").textContent = text
    this.messagesTarget.appendChild(row)
    this.scroll()
    return id
  }

  addMessageHtml(html, type) {
    const row = this._buildMessageRow(type)
    row.querySelector(".chat-message").innerHTML = html
    this.messagesTarget.appendChild(row)
    this.scroll()
  }

  addImageMessage(imageSrc, text) {
    const row = this._buildMessageRow("user")
    const bubble = row.querySelector(".chat-message")
    let html = `<img src="${imageSrc}" style="max-width:200px;max-height:150px;border-radius:8px;display:block;margin-bottom:4px;" />`
    if (text) html += `<span>${this.escapeHtml(text)}</span>`
    bubble.innerHTML = html
    this.messagesTarget.appendChild(row)
    this.scroll()
  }

  addDocumentMessage(filename, text) {
    const row = this._buildMessageRow("user")
    const bubble = row.querySelector(".chat-message")
    let html = `<span style="font-size:12px;color:#4a5568;">📄 ${this.escapeHtml(filename)}</span>`
    if (text) html += `<br><span>${this.escapeHtml(text)}</span>`
    bubble.innerHTML = html
    this.messagesTarget.appendChild(row)
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

  // Mobile: tap a KB document card to append/remove [DocName] from the textarea
  toggleDocSelection(event) {
    const btn = event.currentTarget
    const docName = btn.dataset.docName
    const docTag = `[${docName}]`
    const isSelected = btn.dataset.selected === "true"
    const checkbox = btn.querySelector(".kb-doc-checkbox")

    if (isSelected) {
      btn.dataset.selected = "false"
      if (checkbox) checkbox.innerHTML = ""
      const lines = this.inputTarget.value.split("\n")
      this.inputTarget.value = lines.filter(l => l.trim() !== docTag).join("\n").trim()
    } else {
      btn.dataset.selected = "true"
      if (checkbox) {
        checkbox.innerHTML = `<svg style="width:14px;height:14px;display:block;" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="3"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg>`
      }
      const current = this.inputTarget.value.trim()
      this.inputTarget.value = current ? `${current}\n${docTag}` : docTag
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  addIndexedMessage(data) {
    const row = this._buildMessageRow("system")
    const bubble = row.querySelector(".chat-message")

    const canonical = data.canonical_name || (data.filenames && data.filenames[0]) || "Documento"
    const aliases = Array.isArray(data.aliases) && data.aliases.length ? data.aliases : null

    let html = `<span>✅ <strong>${this.escapeHtml(canonical)}</strong> indexado correctamente.</span>`
    if (aliases) {
      const pills = aliases.map(a =>
        `<span style="display:inline-block;background:#e2e8f0;border-radius:9999px;padding:1px 8px;font-size:11px;margin:2px 2px 0 0;">${this.escapeHtml(a)}</span>`
      ).join("")
      html += `<div style="margin-top:4px;font-size:12px;color:#4a5568;">Consúltame por: ${pills}</div>`
    }

    bubble.innerHTML = html
    this.messagesTarget.appendChild(row)
    this.scroll()
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

      // Turbo processes the stream asynchronously — wait one animation frame so
      // the DOM is updated before we reset the scroll position to reveal the
      // newest document at the top of the list.
      requestAnimationFrame(() => {
        this.element.querySelector(".mobile-docs-panel")?.scrollTo({ top: 0 })
        document
          .querySelector("#kb-docs-desktop-items")
          ?.closest(".overflow-y-auto")
          ?.scrollTo({ top: 0 })
      })
    } catch (error) {
      console.error('Error refreshing documents:', error)
    }
  }

}
