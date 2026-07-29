// app/javascript/rag/sources_renderer.js
//
// Single consolidated "Fuentes:"/"Sources:" block, replacing the old
// documents_consulted_renderer.js (excerpt callout + name-only list, shown
// before the answer) and references_renderer.js (shown after the answer,
// filtered to citations without an excerpt). One row per citation covers both
// cases, so no [n] cited inline is ever missing a row and none is duplicated.

const CIRCLED_NUMERALS = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]

function escape(text = "") {
  const div = document.createElement("div")
  div.textContent = text
  return div.innerHTML
}

// The sidecar already carries canonical_name in metadata, so prefer it over the
// raw filename/title (which fall back to chunk_N.txt when nothing else is set).
export function resolveName(citation) {
  return (citation.metadata?.canonical_name || citation.title || citation.filename || "Document").trim()
}

// JS has no access to Rails i18n; kept in sync by hand with `rag.sources_label`
// in config/locales/rag.*.yml. Detection matches the previous renderers'.
function sourcesTitle() {
  const lang = (document.documentElement.lang || "es").toLowerCase()
  return lang.startsWith("en") ? "Sources:" : "Fuentes:"
}

// @param {Array<{number, filename, title, page, metadata, matched_excerpt}>} citations
// @returns {string} HTML snippet (empty string when no citations)
export function renderSources(citations = []) {
  const safe = Array.isArray(citations) ? citations : []
  if (!safe.length) return ""

  const rows = safe.map((citation, index) => {
    const bullet = citation.number ? `[${citation.number}]` : (CIRCLED_NUMERALS[index] || `${index + 1}.`)
    const name = resolveName(citation)
    const pageSuffix = citation.page ? `, p. ${citation.page}` : ""
    const excerpt = (citation.matched_excerpt || "").trim()
    const excerptSuffix = excerpt ? ` &mdash; &ldquo;${escape(excerpt)}&rdquo;` : ""
    return (
      `<li><span class="chat-sources-bullet">${bullet}</span>` +
      `<span class="chat-sources-name">${escape(name)}${escape(pageSuffix)}</span>${excerptSuffix}</li>`
    )
  }).join("")

  return `
    <div class="chat-sources">
      <p class="chat-sources-title">${sourcesTitle()}</p>
      <ul class="chat-sources-list">${rows}</ul>
    </div>
  `
}
