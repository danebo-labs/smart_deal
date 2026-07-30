const VISIBLE_CARD_LIMIT = 3
const SUPPORTED_MODES = new Set(["direct", "ambiguous", "insufficient", "not_applicable"])

function escapeHtml(value = "") {
  const element = document.createElement("div")
  element.textContent = String(value)
  return element.innerHTML
}

function safeEvidenceUrl(value) {
  if (!value) return null

  try {
    const url = new URL(value, document.baseURI)
    return ["http:", "https:"].includes(url.protocol) ? url.href : null
  } catch (_error) {
    return null
  }
}

function cardMarkup(card, { selectable, copy }) {
  const breadcrumb = Array.isArray(card.breadcrumb) ? card.breadcrumb.filter(Boolean) : []
  const breadcrumbHtml = breadcrumb.length
    ? `<nav class="rag-evidence-breadcrumb" aria-label="${escapeHtml(copy.breadcrumb_label)}">${breadcrumb.map(escapeHtml).join("<span aria-hidden=\"true\">›</span>")}</nav>`
    : ""
  const page = Number.isInteger(card.page) && card.page > 0
    ? `<span class="rag-evidence-page">${escapeHtml(copy.page)} ${card.page}</span>`
    : ""
  const evidenceUrl = safeEvidenceUrl(card.evidence_url)
  const evidenceLink = evidenceUrl
    ? `<a class="rag-evidence-secondary-action" href="${escapeHtml(evidenceUrl)}" target="_blank" rel="noopener noreferrer">${escapeHtml(copy.view_document)}</a>`
    : ""
  const selectAction = selectable && card.select_query
    ? `<button type="button" class="rag-evidence-primary-action" data-action="click->rag-chat#sendQuickReply" data-query="${escapeHtml(card.select_query)}">${escapeHtml(copy.use_board)}</button>`
    : ""

  return `
    <article class="rag-evidence-card" data-evidence-card-id="${escapeHtml(card.id)}">
      <h3 class="rag-evidence-card-label">${escapeHtml(card.label)}</h3>
      ${breadcrumbHtml}
      <blockquote class="rag-evidence-excerpt">${escapeHtml(card.excerpt)}</blockquote>
      ${(page || evidenceLink || selectAction) ? `<div class="rag-evidence-actions">${page}${selectAction}${evidenceLink}</div>` : ""}
    </article>
  `
}

function cardsMarkup(cards, options) {
  return cards.map((card) => cardMarkup(card, options)).join("")
}

function insufficientMarkup(resolution, copy) {
  const reason = copy.insufficient_reason?.[resolution.insufficient_reason] || copy.insufficient
  const abstentions = Array.isArray(resolution.abstained_relations)
    ? resolution.abstained_relations
      .map((relation) => copy.abstained_relations?.[relation])
      .filter(Boolean)
    : []

  return `
    <aside class="rag-resolution-status" role="status">
      <p>${escapeHtml(reason)}</p>
      ${abstentions.map((message) => `<p>${escapeHtml(message)}</p>`).join("")}
    </aside>
  `
}

export function hasSelectableEvidenceCards(resolution) {
  return resolution?.mode === "ambiguous" &&
    Array.isArray(resolution.evidence_cards) &&
    resolution.evidence_cards.some((card) => card?.select_query)
}

export function renderEvidenceResolution(resolution, copy = {}) {
  const mode = resolution?.mode
  if (!SUPPORTED_MODES.has(mode) || mode === "not_applicable") return ""
  if (mode === "insufficient") return insufficientMarkup(resolution, copy)

  const cards = Array.isArray(resolution.evidence_cards)
    ? resolution.evidence_cards.filter((card) => card?.excerpt && card?.label)
    : []
  if (!cards.length) return ""

  if (mode === "direct") {
    return `
      <details class="rag-direct-evidence">
        <summary>${escapeHtml(copy.evidence_label)}</summary>
        <div class="rag-evidence-card-list">${cardsMarkup(cards, { selectable: false, copy })}</div>
      </details>
    `
  }

  const visibleCards = cards.slice(0, VISIBLE_CARD_LIMIT)
  const remainingCards = cards.slice(VISIBLE_CARD_LIMIT)
  const remaining = remainingCards.length
  const moreLabel = String(copy.show_more_contexts || "").replace("%{count}", remaining)

  return `
    <section class="rag-evidence-resolution" aria-label="${escapeHtml(copy.cards_label)}">
      <p class="rag-resolution-prompt">${escapeHtml(copy.ambiguous)}</p>
      <div class="rag-evidence-card-list">${cardsMarkup(visibleCards, { selectable: true, copy })}</div>
      ${remaining ? `
        <details class="rag-evidence-more">
          <summary>${escapeHtml(moreLabel)}</summary>
          <div class="rag-evidence-card-list">${cardsMarkup(remainingCards, { selectable: true, copy })}</div>
        </details>
      ` : ""}
    </section>
  `
}
