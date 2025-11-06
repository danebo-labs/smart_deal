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
      credentials: 'same-origin'
    })
    .then(response => {
      if (response.ok) {
        return response.text()
      }
      throw new Error('Network response was not ok')
    })
    .then(html => {
      console.log("Response received:", html.substring(0, 200))
      
      // Parse the HTML response to get turbo-stream elements
      const parser = new DOMParser()
      const doc = parser.parseFromString(html, 'text/html')
      const streamElements = doc.querySelectorAll('turbo-stream')
      
      console.log("Found turbo-stream elements:", streamElements.length)
      
      if (streamElements.length === 0) {
        console.error("No turbo-stream elements found in response")
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

