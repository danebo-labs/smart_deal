// app/javascript/rag/documents_consulted_renderer.js
//
// Renders the opening "Documentos consultados" block that tells the technician
// at a glance which KB documents were used to generate the current answer.
// Mirrors the WhatsApp header built in RagQueryConcern#build_documents_consulted_header.

const CIRCLED_NUMERALS = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]

function escape(text = "") {
  const div = document.createElement("div")
  div.textContent = text
  return div.innerHTML
}

// @param {Array<{number, filename, title}>} citations
// @returns {string} HTML snippet (empty string when no citations)
export function renderDocumentsConsulted(citations = []) {
  const safe = Array.isArray(citations) ? citations : []
  if (!safe.length) return ""

  // Dedup by filename — Haiku may cite the same doc in multiple [n] markers.
  const seen = new Set()
  const uniqueNames = []
  for (const c of safe) {
    const name = (c.filename || c.title || "Document").trim()
    if (!name || seen.has(name)) continue
    seen.add(name)
    uniqueNames.push(name)
  }
  if (!uniqueNames.length) return ""

  const items = uniqueNames.map((name, i) => {
    const bullet = CIRCLED_NUMERALS[i] || `${i + 1}.`
    return `<li><span class="docs-consulted-bullet">${bullet}</span><span class="docs-consulted-name">${escape(name)}</span></li>`
  }).join("")

  return `
    <div class="docs-consulted">
      <p class="docs-consulted-title">📄 Documentos consultados</p>
      <ul class="docs-consulted-list">${items}</ul>
    </div>
  `
}
