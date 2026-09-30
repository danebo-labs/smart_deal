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

// Guardrail del piloto (decisión #8, componente A —
// docs/rag/plan_ciclo4_ajuste_final_2026-08-03.md Fase 3): aviso ESTÁTICO de
// verificación para toda respuesta del chat web. Deliberadamente sin
// clasificador por pregunta (restricción 6; `safety_critical_query?` ya
// demostró no reconocer preguntas de bypass — ciclo 3 Fase 1): se aplica por
// igual a todas las respuestas. Esta función nunca recibe ni toca
// `answer` — el llamador la concatena por fuera del HTML derivado del string
// `answer` del JSON, para que el gate/artefactos de benchmark no se
// contaminen (E7).
const VERIFICATION_NOTICE_COPY = {
  es: "Asistencia de consulta al manual — verifica cualquier acción sobre seguridades contra el manual antes de ejecutarla.",
  en: "Manual-lookup assistance — verify any action on safety devices against the manual before performing it."
}

export function renderVerificationNotice(lang = "es") {
  const copy = String(lang).toLowerCase().startsWith("en")
    ? VERIFICATION_NOTICE_COPY.en
    : VERIFICATION_NOTICE_COPY.es
  return `<p class="answer-verification-notice" role="note">${escapeHtml(copy)}</p>`
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

// The server already decided `band`. These labels only display it.
// A prompt prefix is removed when it repeats that label; it never selects the band.
const PROVENANCE_LABELS = {
  MANUAL_FACT: "Manual",
  VISUAL_OBSERVATION: "Foto",
  DANEBO_GUIDANCE: "Guía Danebo"
}

const PROVENANCE_PREFIX = {
  MANUAL_FACT: "Según el manual:",
  VISUAL_OBSERVATION: "En la foto:",
  DANEBO_GUIDANCE: "Para revisar:"
}

function validSegment(segment) {
  if (!segment || typeof segment !== "object" || Array.isArray(segment)) return false
  if (typeof segment.band !== "string" || segment.band.length === 0) return false
  return typeof segment.text === "string"
}

function provenanceGroups(segments) {
  if (!Array.isArray(segments) || segments.length === 0) return null

  const items = []
  for (const segment of segments) {
    if (!validSegment(segment)) return null
    if (segment.text.trim() === "") continue
    items.push({ band: segment.band, text: segment.text })
  }
  if (items.length === 0) return null

  const groups = []
  items.forEach((item) => {
    const last = groups[groups.length - 1]
    if (last && last.band === item.band) {
      last.texts.push(item.text)
    } else {
      groups.push({ band: item.band, texts: [ item.text ] })
    }
  })
  return groups
}

function textForBand(band, text) {
  const prefix = PROVENANCE_PREFIX[band]
  if (!prefix) return text

  const body = text.trimStart()
  if (!body.startsWith(prefix)) return text

  const rest = body.slice(prefix.length).trimStart()
  return rest ? rest : text
}

function joinProvenanceText(parts) {
  return parts.reduce((acc, part) => {
    if (acc === "") return part
    if (/\s$/.test(acc) || /^\s/.test(part)) return acc + part
    return `${acc} ${part}`
  }, "")
}

function renderProvenanceGroup(group, citations) {
  const text = joinProvenanceText(group.texts.map((part) => textForBand(group.band, part)))
  const html = renderMarkdownAnswer(text, citations)
  const label = PROVENANCE_LABELS[group.band]
  if (!label) return html

  return (
    `<div class="answer-provenance" data-provenance-band="${escapeHtml(group.band)}">` +
      `<p class="answer-provenance-label">${escapeHtml(label)}</p>` +
      `<div class="answer-provenance-text">${html}</div>` +
    `</div>`
  )
}

// Drop-in replacement for formatAnswer used by rag_chat_controller for web answers.
// The backend already decides whether a [n] marker survives (RagController strips
// markers that resolve to a real citation when SHOW_RAG_SOURCES is off, preserving
// non-resolving markers like a literal "[24]" pin/terminal — see
// docs/RAG_RESOLUTION_MODE_CONTRACT_FASE3_2026-07-29.md §1 C2). So there is a single
// rule here regardless of flag state: wrap a marker as a citation span only if it
// resolves against `citations`; otherwise leave it untouched.
//
// `segments` is optional. Missing, null, empty, or malformed input keeps this
// renderer. A usable list replaces the answer string and does not classify it.
export function formatAnswerForWeb(answerText, citations = [], segments) {
  const groups = provenanceGroups(segments)
  if (!groups) return renderMarkdownAnswer(answerText, citations)

  const parts = groups.map((group) => renderProvenanceGroup(group, citations))
  if (!groups.some((group) => PROVENANCE_LABELS[group.band])) return parts.join("")
  return `<div class="answer-provenance-list">${parts.join("")}</div>`
}

function renderMarkdownAnswer(answerText, citations) {
  const safeCitations = Array.isArray(citations) ? citations : []

  const citationMap = {}
  safeCitations.forEach(c => { if (c.number) citationMap[c.number] = c })

  const escaped      = escapeHtml(answerText)
  const withMarkdown = markdownToHtml(escaped)

  return withMarkdown.replace(/\[(\d+)\]/g, (match, num) => {
    const citation = citationMap[num]
    if (!citation) return match

    const title   = citation.title || citation.filename || "Document"
    const excerpt = citation.tooltip_excerpt || ""
    const tooltip = escapeHtml(excerpt ? `${title} – ${excerpt}` : title)

    return `<span class="citation" title="${tooltip}" data-citation-number="${num}">[${num}]</span>`
  })
}
