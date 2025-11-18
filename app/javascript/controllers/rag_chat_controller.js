// app/javascript/controllers/rag_chat_controller.js

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "sendButton", "messages", "chatContainer"]

  connect() {
    console.log("RAG chat controller connected")
    // Focus on input when connected
    if (this.hasInputTarget) {
      this.inputTarget.focus()
    }
  }

  async sendMessage(event) {
    event.preventDefault()
    
    const question = this.inputTarget.value.trim()
    
    if (!question) {
      return
    }

    // Disable input and button
    this.inputTarget.disabled = true
    if (this.hasSendButtonTarget) {
      this.sendButtonTarget.disabled = true
      this.sendButtonTarget.textContent = "Sending..."
    }

    // Add user message to chat
    this.addMessage(question, "user")

    // Clear input
    this.inputTarget.value = ""

    // Show loading message
    const loadingId = this.addMessage("Thinking...", "assistant", true)

    try {
      const response = await fetch('/rag/ask', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
        },
        credentials: 'same-origin',
        body: JSON.stringify({ question: question })
      })

      const data = await response.json()

      // Remove loading message
      this.removeMessage(loadingId)

      if (data.status === 'success') {
        // Add assistant response
        this.addMessage(data.answer, "assistant")
        
        // Show citations with details if available
        if (data.citations && data.citations.length > 0) {
          let citationsHtml = `<div style="margin-top: 0.5rem; padding-top: 0.5rem; border-top: 1px solid rgba(255,255,255,0.1);">`
          citationsHtml += `<div style="font-weight: 600; margin-bottom: 0.5rem;">📚 ${data.citations.length} document(s) consulted:</div>`
          
          data.citations.forEach((citation, index) => {
            citationsHtml += `<div style="margin-bottom: 0.25rem; font-size: 0.875rem; opacity: 0.9;">`
            citationsHtml += `  ${index + 1}. <strong>${citation.file_name || 'Document'}</strong>`
            if (citation.uri) {
              citationsHtml += ` <span style="opacity: 0.7;">(${citation.uri.split('/').pop()})</span>`
            }
            citationsHtml += `</div>`
          })
          
          citationsHtml += `</div>`
          
          // Add citations as a system message with HTML content
          this.addMessageWithHtml(citationsHtml, "system")
        } else {
          // Warn if no citations found
          this.addMessage("⚠️ No documents found related to your question.", "system")
        }
      } else {
        throw new Error(data.message || 'Unknown error')
      }
    } catch (error) {
      console.error('RAG query error:', error)
      // Remove loading message
      this.removeMessage(loadingId)
      // Show error
      this.addMessage(`Error: ${error.message}`, "error")
    } finally {
      // Re-enable input and button
      this.inputTarget.disabled = false
      if (this.hasSendButtonTarget) {
        this.sendButtonTarget.disabled = false
        this.sendButtonTarget.textContent = "Send"
      }
      // Focus on input for next question
      this.inputTarget.focus()
    }
  }

  addMessage(text, type = "user", isTemporary = false) {
    if (!this.hasMessagesTarget) return null

    const messageDiv = document.createElement("div")
    const messageId = `msg-${Date.now()}-${Math.random()}`
    messageDiv.id = messageId
    messageDiv.className = `chat-message chat-message-${type}`
    
    if (isTemporary) {
      messageDiv.dataset.temporary = "true"
    }

    const messageText = document.createElement("div")
    messageText.className = "chat-message-text"
    messageText.textContent = text
    messageDiv.appendChild(messageText)

    this.messagesTarget.appendChild(messageDiv)
    
    // Auto-scroll to bottom
    this.scrollToBottom()

    return messageId
  }

  addMessageWithHtml(html, type = "user", isTemporary = false) {
    if (!this.hasMessagesTarget) return null

    const messageDiv = document.createElement("div")
    const messageId = `msg-${Date.now()}-${Math.random()}`
    messageDiv.id = messageId
    messageDiv.className = `chat-message chat-message-${type}`
    
    if (isTemporary) {
      messageDiv.dataset.temporary = "true"
    }

    const messageText = document.createElement("div")
    messageText.className = "chat-message-text"
    messageText.innerHTML = html
    messageDiv.appendChild(messageText)

    this.messagesTarget.appendChild(messageDiv)
    
    // Auto-scroll to bottom
    this.scrollToBottom()

    return messageId
  }

  removeMessage(messageId) {
    const message = document.getElementById(messageId)
    if (message) {
      message.remove()
    } else {
      // Try to remove temporary messages
      const temporaryMessages = this.messagesTarget.querySelectorAll('[data-temporary="true"]')
      temporaryMessages.forEach(msg => msg.remove())
    }
  }

  scrollToBottom() {
    if (this.hasChatContainerTarget) {
      this.chatContainerTarget.scrollTop = this.chatContainerTarget.scrollHeight
    } else if (this.hasMessagesTarget) {
      this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    }
  }

  handleKeyPress(event) {
    // Send on Enter, but allow Shift+Enter for new line
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.sendMessage(event)
    }
  }
}

