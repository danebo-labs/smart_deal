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
// in config/locales/rag.*.yml.
function sourcesLabel(count, lang) {
  return String(lang || "es").toLowerCase().startsWith("en") ? `Sources (${count})` : `Fuentes (${count})`
}

// Returns a <details> fragment meant to live INSIDE the answer bubble, not as
// its own .chat-message row — a separate row inherits the assistant card style
// and reads as a tappable button that does nothing.
// @param lang [String] response_locale for this answer — caller-supplied so this
//   module never reads document.documentElement.lang (auth-time locale switcher
//   must not leak into chat chrome — P0 idioma). Defaults to "es".
export function renderSources(citations = [], lang = "es") {
  const safe = Array.isArray(citations) ? citations : []
  if (!safe.length) return ""

  const rows = safe.map((citation, index) => {
    const bullet = citation.number ? `[${citation.number}]` : (CIRCLED_NUMERALS[index] || `${index + 1}.`)
    const name = resolveName(citation)
    // citation_processor.rb#build_numbered_references already appends " — p. N"
    // to `title`, so adding it blindly yields "… — p. 82, p. 82" whenever
    // metadata.canonical_name is absent and resolveName falls back to title.
    const page = citation.page
    const alreadyPaged = page && new RegExp(`p\\.?\\s*${page}\\s*$`, "i").test(name)
    const pageSuffix = page && !alreadyPaged ? `, p. ${page}` : ""
    const excerpt = (citation.matched_excerpt || "").trim()
    const excerptSuffix = excerpt ? ` &mdash; &ldquo;${escape(excerpt)}&rdquo;` : ""
    return (
      `<li><span class="chat-sources-bullet">${bullet}</span>` +
      `<span class="chat-sources-name">${escape(name)}${escape(pageSuffix)}</span>${excerptSuffix}</li>`
    )
  }).join("")

  return `
    <details class="chat-sources">
      <summary class="chat-sources-toggle">${sourcesLabel(safe.length, lang)}</summary>
      <ul class="chat-sources-list">${rows}</ul>
    </details>
  `
}
