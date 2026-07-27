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

// The sidecar already carries canonical_name in metadata, so prefer it over the
// raw filename/title (which fall back to chunk_N.txt when nothing else is set).
function resolveName(citation) {
  return (citation.metadata?.canonical_name || citation.title || citation.filename || "Document").trim()
}

function renderList(title, items) {
  return `
    <div class="docs-consulted">
      <p class="docs-consulted-title">${title}</p>
      <ul class="docs-consulted-list">${items}</ul>
    </div>
  `
}

// Current behavior, preserved byte-for-byte: dedup by resolved document name,
// one row per unique document, numbered with the circled numerals.
function renderNameFallback(citations) {
  const seen = new Set()
  const uniqueNames = []
  for (const c of citations) {
    const name = resolveName(c)
    if (!name || seen.has(name)) continue
    seen.add(name)
    uniqueNames.push(name)
  }
  if (!uniqueNames.length) return ""

  const items = uniqueNames.map((name, i) => {
    const bullet = CIRCLED_NUMERALS[i] || `${i + 1}.`
    return `<li><span class="docs-consulted-bullet">${bullet}</span><span class="docs-consulted-name">${escape(name)}</span></li>`
  }).join("")

  return renderList("📄 Documentos consultados", items)
}

// One row per citation with a matched_excerpt, deduped by the excerpt text
// itself — several citations from the same document can carry distinct
// excerpts and all of them are worth showing.
function renderExcerpts(citations) {
  const seen = new Set()
  const rows = []
  for (const c of citations) {
    const excerpt = (c.matched_excerpt || "").trim()
    if (!excerpt || seen.has(excerpt)) continue
    seen.add(excerpt)

    // V7: use the citation's own [n] marker as the bullet when present, so
    // filtering it out of the "Referencias" block below (rag_chat_controller)
    // never leaves a [n] in the answer text with no corresponding row anywhere.
    const bullet = c.number ? `[${c.number}]` : (CIRCLED_NUMERALS[rows.length] || `${rows.length + 1}.`)
    const name = resolveName(c)
    const pageSuffix = c.page ? `, p. ${c.page}` : ""
    rows.push(
      `<li><span class="docs-consulted-bullet">${bullet}</span>` +
      `<span class="docs-consulted-excerpt">&ldquo;${escape(excerpt)}&rdquo; — ${escape(name)}${escape(pageSuffix)}</span></li>`
    )
  }
  if (!rows.length) return ""

  const lang = (document.documentElement.lang || "es").toLowerCase()
  const heading = lang.startsWith("en") ? "🔎 Excerpt matching your question" : "🔎 Extracto que coincide con tu consulta"
  return renderList(heading, rows.join(""))
}

// @param {Array<{number, filename, title, page, metadata, matched_excerpt}>} citations
// @returns {string} HTML snippet (empty string when no citations)
export function renderDocumentsConsulted(citations = []) {
  const safe = Array.isArray(citations) ? citations : []
  if (!safe.length) return ""

  const withExcerpts = safe.filter((c) => (c.matched_excerpt || "").trim())
  if (withExcerpts.length) {
    const rendered = renderExcerpts(withExcerpts)
    if (rendered) return rendered
  }

  return renderNameFallback(safe)
}
