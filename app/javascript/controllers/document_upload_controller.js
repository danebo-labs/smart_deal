import { Controller } from "@hotwired/stimulus"
import * as Turbo from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = ["fileInput", "uploadButton", "dashedBorder"]

  connect() {
    console.log("Document upload controller connected")
    console.log("File input target:", this.hasFileInputTarget ? "found" : "not found")
    console.log("Upload button target:", this.hasUploadButtonTarget ? "found" : "not found")
  }

  // Handle file selection
  selectFile(event) {
    const file = event.target.files[0]
    if (file) {
      this.validateAndSubmit(file)
      // Reset the input so the same file can be selected again if needed
      event.target.value = ''
    }
  }

  // Handle drag and drop
  dragOver(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.hasDashedBorderTarget) {
      this.dashedBorderTarget.style.borderColor = "#2563eb"
      this.dashedBorderTarget.style.backgroundColor = "#eff6ff"
    }
  }

  dragLeave(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.hasDashedBorderTarget) {
      this.dashedBorderTarget.style.borderColor = "#cbd5e0"
      this.dashedBorderTarget.style.backgroundColor = "#f7fafc"
    }
  }

  drop(event) {
    event.preventDefault()
    event.stopPropagation()
    
    if (this.hasDashedBorderTarget) {
      this.dashedBorderTarget.style.borderColor = "#cbd5e0"
      this.dashedBorderTarget.style.backgroundColor = "#f7fafc"
    }

    const files = event.dataTransfer.files
    if (files.length > 0) {
      this.validateAndSubmit(files[0])
    }
  }

  // Handle click on upload area
  clickUpload(event) {
    console.log("clickUpload called", event.target)
    // Don't trigger if clicking the button (button has its own handler)
    const isButton = event.target === this.uploadButtonTarget || 
                     (this.hasUploadButtonTarget && this.uploadButtonTarget.contains(event.target))
    
    if (isButton) {
      console.log("Click was on button, ignoring")
      return
    }
    
    // For any other click in the area, open file dialog
    if (this.hasFileInputTarget) {
      console.log("Opening file dialog")
      this.fileInputTarget.click()
    } else {
      console.error("File input target not found!")
    }
  }

  // Handle click on button
  clickButton(event) {
    console.log("clickButton called")
    event.preventDefault()
    event.stopPropagation()
    if (this.hasFileInputTarget) {
      console.log("Opening file dialog from button")
      this.fileInputTarget.click()
    } else {
      console.error("File input target not found!")
    }
  }

  // Validate and submit file
  validateAndSubmit(file) {
    // Validate file type
    if (!file.type.includes('pdf') && !file.name.toLowerCase().endsWith('.pdf')) {
      this.showError('Please upload a PDF file.')
      return
    }

    // Show loading state immediately
    this.showLoading()

    // Create FormData and submit
    const formData = new FormData()
    formData.append('file', file)

    // Get CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    // Submit via Turbo Streams
    fetch('/documents/process', {
      method: 'POST',
      body: formData,
      headers: {
        'Accept': 'text/vnd.turbo-stream.html',
        'X-CSRF-Token': csrfToken
      },
      credentials: 'same-origin',
      redirect: 'manual' // Handle redirects manually
    })
    .then(response => {
      console.log("Response status:", response.status, "ok:", response.ok, "type:", response.type)
      
      // When redirect: 'manual' is used, redirects become "opaqueredirect" with status 0
      // Headers are not accessible for security reasons, but we know it's a redirect
      if (response.type === 'opaqueredirect' || (response.status === 0 && response.type !== 'error')) {
        console.log("Opaque redirect detected (likely auth redirect), redirecting to login")
        this.clearLoading()
        // Redirect immediately without showing any error
        Turbo.visit('/users/sign_in')
        // Return early to prevent any further processing
        throw new Error('AUTH_REDIRECT') // Use throw to prevent catch from showing user-facing error
      }
      
      // Check for redirect Location header (for accessible redirects)
      const redirectUrl = response.headers.get('Location')
      
      // Handle explicit redirects (302, 303, etc.)
      if (redirectUrl || (response.status >= 300 && response.status < 400)) {
        console.log("Redirect detected, Location:", redirectUrl)
        this.clearLoading()
        const finalUrl = redirectUrl || '/users/sign_in'
        Turbo.visit(finalUrl)
        return null
      }
      
      // Handle authentication errors (401, 403) - direct errors without redirect
      if (response.status === 401 || response.status === 403) {
        console.log("Authentication error detected (401/403), redirecting to login")
        this.clearLoading()
        Turbo.visit('/users/sign_in')
        return null
      }
      
      // Handle other errors
      if (!response.ok) {
        console.log("Other error detected:", response.status)
        this.clearLoading()
        this.showError(`Server error (${response.status}). Please try again.`)
        return null
      }
      
      return response.text()
    })
    .then(html => {
      // If html is null, we already handled redirect/error
      if (!html) return
      
      console.log("Response received:", html.substring(0, 200))
      
      // Parse the HTML response to get turbo-stream elements
      const parser = new DOMParser()
      const doc = parser.parseFromString(html, 'text/html')
      const streamElements = doc.querySelectorAll('turbo-stream')
      
      console.log("Found turbo-stream elements:", streamElements.length)
      
      if (streamElements.length === 0) {
        console.error("No turbo-stream elements found in response")
        this.clearLoading()
        return
      }
      
      // Process each turbo-stream element using Turbo's native method
      streamElements.forEach((streamElement, index) => {
        const action = streamElement.getAttribute('action')
        const target = streamElement.getAttribute('target')
        console.log(`Processing stream ${index + 1}: action=${action}, target=${target}`)
        
        // Verify the target exists BEFORE processing
        const targetElement = document.getElementById(target)
        if (targetElement) {
          console.log(`Target element found: ${target}`)
        } else {
          console.warn(`Target element NOT found: ${target}`)
        }
        
        // Use Turbo's StreamElement to process the stream
        // Turbo automatically processes streams when they're added to the DOM
        const clonedStream = streamElement.cloneNode(true)
        document.body.appendChild(clonedStream)
        
        // Turbo processes streams synchronously, remove after processing
        setTimeout(() => {
          if (clonedStream.parentNode) {
            clonedStream.parentNode.removeChild(clonedStream)
          }
        }, 100)
      })
      
      // Reset file input after successful upload
      if (this.hasFileInputTarget) {
        this.fileInputTarget.value = ''
      }
    })
    .catch(error => {
      console.error('Error:', error)
      
      // Don't show error if it's an auth redirect (we already handled it above)
      if (error.message === 'AUTH_REDIRECT') {
        console.log("Auth redirect already handled, ignoring error")
        return // Exit silently
      }
      
      // Don't show error for network errors that might be from redirects
      if (error.name === 'TypeError' && error.message.includes('Failed to fetch')) {
        console.log("Network error (possibly from redirect), clearing loading only")
        this.clearLoading()
        return // Exit without showing error
      }
      
      // For other errors, show the error message
      this.clearLoading()
      this.showError('Failed to process document. Please try again.')
    })
  }

  showLoading() {
    // Show loading in both turbo frames
    const documentInfo = document.getElementById('document_info')
    const aiSummary = document.getElementById('ai_summary')
    
    if (documentInfo) {
      documentInfo.innerHTML = `
        <div class="document-info-content">
          <div style="text-align: center; padding: 2rem;">
            <div style="width: 40px; height: 40px; border: 4px solid #e2e8f0; border-top-color: #2563eb; border-radius: 50%; animation: spin 1s linear infinite; margin: 0 auto 1rem;"></div>
            <p style="color: #718096; margin: 0;">Processing document...</p>
            <style>
              @keyframes spin {
                to { transform: rotate(360deg); }
              }
            </style>
          </div>
        </div>
      `
    }
    
    if (aiSummary) {
      aiSummary.innerHTML = `
        <div class="explanation-content-wrapper">
          <div class="explanation-content">
            <div style="text-align: center; padding: 2rem;">
              <div style="width: 40px; height: 40px; border: 4px solid #e2e8f0; border-top-color: #2563eb; border-radius: 50%; animation: spin 1s linear infinite; margin: 0 auto 1rem;"></div>
              <p style="color: #718096; margin: 0;">Analyzing document with AI...</p>
              <style>
                @keyframes spin {
                  to { transform: rotate(360deg); }
                }
              </style>
            </div>
          </div>
        </div>
      `
    }
  }

  clearLoading() {
    // Clear loading state from both turbo frames
    const documentInfo = document.getElementById('document_info')
    const aiSummary = document.getElementById('ai_summary')
    
    if (documentInfo) {
      // Reset to placeholder
      documentInfo.innerHTML = `
        <div class="document-info-placeholder">
          <svg width="80" height="80" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" class="document-placeholder-icon">
            <path d="M14 2H6C5.46957 2 4.96086 2.21071 4.58579 2.58579C4.21071 2.96086 4 3.46957 4 4V20C4 20.5304 4.21071 21.0391 4.58579 21.4142C4.96086 21.7893 5.46957 22 6 22H18C18.5304 22 19.0391 21.7893 19.4142 21.4142C19.7893 21.0391 20 20.5304 20 20V8L14 2Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
            <path d="M14 2V8H20" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
            <path d="M16 13H8M16 17H8M10 9H8" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
          </svg>
          <p class="document-placeholder-text">No document uploaded yet</p>
        </div>
      `
    }
    
    if (aiSummary) {
      // Reset to placeholder
      aiSummary.innerHTML = `
        <div class="explanation-content-wrapper">
          <div class="explanation-content">
            <p class="explanation-placeholder">
              Upload a document to see the AI-generated summary here. The analysis will include key points, main topics, and important insights extracted from your document.
            </p>
            
            <div class="explanation-features">
              <div class="feature-item">
                <span class="feature-bullet">•</span>
                <p>Automatic extraction of key concepts and themes</p>
              </div>
              <div class="feature-item">
                <span class="feature-bullet">•</span>
                <p>Concise summaries of long documents</p>
              </div>
              <div class="feature-item">
                <span class="feature-bullet">•</span>
                <p>Identification of important action items</p>
              </div>
            </div>
          </div>
        </div>
      `
    }
  }

  showError(message) {
    // Show error in document info frame
    const documentInfo = document.getElementById('document_info')
    if (documentInfo) {
      documentInfo.innerHTML = `
        <div class="document-info-content">
          <div style="background: #fee; border: 1px solid #fcc; border-radius: 0.5rem; padding: 1rem; color: #c33;">
            <strong>Error:</strong> ${message}
          </div>
        </div>
      `
    }
    
    // Also clear AI summary loading
    const aiSummary = document.getElementById('ai_summary')
    if (aiSummary) {
      aiSummary.innerHTML = `
        <div class="explanation-content-wrapper">
          <div class="explanation-content">
            <p class="explanation-placeholder">
              Upload a document to see the AI-generated summary here.
            </p>
          </div>
        </div>
      `
    }
  }

  // Format file size helper
  formatFileSize(bytes) {
    if (bytes === 0) return '0 Bytes'
    const k = 1024
    const sizes = ['Bytes', 'KB', 'MB', 'GB']
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i]
  }
}

