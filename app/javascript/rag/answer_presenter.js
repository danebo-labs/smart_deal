// app/javascript/rag/answer_presenter.js
//
// Markdown-aware formatter for web chat answers.
// Use ONLY for web RAG responses — WhatsApp and system messages use plain text.
//
// Pipeline (order is load-bearing, do not reorder):
//   1. escapeHtml(rawText)         — blocks any HTML injection from the model
//   2. markdownToHtml(escaped)     — asterisks survive escapeHtml, safe to match
//   3. replace [n] → citation span — after markdown so markers are never split

const escapeHtml = (text = "") => {
  const div = document.createElement("div")
  div.textContent = text
  return div.innerHTML
}

function markdownToHtml(text) {
  let out = text

  // Bold: **text** → <strong>. Non-greedy, won't cross paragraph boundaries.
  out = out.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")

  // Italic: *text* only when NOT adjacent to another *, avoiding collision
  // with circled numerals ①②③ or lone asterisks in edge cases.
  out = out.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, "<em>$1</em>")

  // Horizontal rule: a line that is only "---" (## headers already stripped by Ruby sanitizer).
  out = out.replace(/^[ \t]*---[ \t]*$/gm, '<hr class="answer-hr">')

  // Paragraph split on double (or more) blank lines, then single \n → <br> within paragraphs.
  const blocks = out.split(/\n{2,}/)
  out = blocks
    .map(block => block.trim())
    .filter(block => block.length > 0)
    .map(block => {
      // Block-level elements already contain their own wrapper — don't double-wrap.
      if (/^<(hr|ul|ol|div|blockquote)/.test(block)) return block
      const inner = block.replace(/\n/g, "<br>")
      return `<p class="answer-p">${inner}</p>`
    })
    .join("")

  return out
}

// Drop-in replacement for formatAnswer used by rag_chat_controller for web answers.
// Keeps the same citation tooltip behaviour as citation_formatter.js#formatAnswer.
export function formatAnswerForWeb(answerText, citations = []) {
  const safeCitations = Array.isArray(citations) ? citations : []

  const citationMap = {}
  safeCitations.forEach(c => { if (c.number) citationMap[c.number] = c })

  const escaped     = escapeHtml(answerText)
  const withMarkdown = markdownToHtml(escaped)

  return withMarkdown.replace(/\[(\d+)\]/g, (_, num) => {
    const citation = citationMap[num]
    const title    = citation?.title || citation?.filename || "Document"
    const content  = citation?.content || ""
    const snippet  = content.length > 150 ? content.slice(0, 150) + "…" : content
    const tooltip  = escapeHtml(snippet ? `${title} – ${snippet}` : title)

    return `<span class="citation" title="${tooltip}" data-citation-number="${num}">[${num}]</span>`
  })
}
