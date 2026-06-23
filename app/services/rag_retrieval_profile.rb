# frozen_string_literal: true

# Resolves adaptive retrieval parameters from session pin signals.
#
# After cost_v2 ingestion, two distinct chunk classes exist:
#   - field_photo_v1  : ~50 tok/chunk  (source="image_upload")
#   - manual_batch_v1 / web_v1 : ~3000 tok/chunk (source="document")
#
# number_of_results is tuned so the token budget passed to Haiku stays roughly
# constant regardless of pin type, reducing unnecessary input cost for document
# sessions while preserving recall for photo sessions.
#
# | Pin signal          | normal | exhaustive | rationale                         |
# |---------------------|--------|------------|-----------------------------------|
# | photos only         | 10     | 10         | photo chunks are small            |
# | documents only      | 3      | 15 -> 12   | rerank full-list candidates       |
# | mixed photo+doc     | 3      | 15 -> 12   | same document budget              |
# | no pin (open query) | 8      | 15         | broader catalog search            |
class RagRetrievalProfile
  PINNED_DOCUMENT_RESULTS = 3
  PHOTO_RESULTS = 10
  OPEN_RESULTS = 8
  SAFETY_CRITICAL_RESULTS = 5
  EXHAUSTIVE_CANDIDATES = 15
  EXHAUSTIVE_RERANKED_RESULTS = 12
  # Open queries that name a schematic designator (-PDCM, -PBCM, -J26…) together
  # with a connector/label keyword need the document's block→connector overview
  # chunk, which ranks below nearer detail pages (observed rank ~11–16). Widen
  # recall to MAX_RESULTS so that overview chunk lands in the generation window.
  # MAX_RESULTS is the largest top-k any path requests and is mirrored by
  # ContractualLimits::QUERY[:max_top_k] (the cost-contract ceiling).
  MAX_RESULTS = 20

  EXHAUSTIVE_PATTERNS = [
    /\b(?:todas|todos|cada)\s+(?:las|los)?\s*(?:pruebas|comprobaciones|pasos|controles|revisiones)\b/i,
    /\b(?:lista|listado)\s+(?:completa|completo)\b/i,
    /\b(?:enumera|enumerar|detalla)\s+(?:todas|todos)\b/i,
    /\b(?:que|qué|cuales|cuáles)\s+(?:son\s+)?(?:las\s+)?pruebas\s+(?:funcionales?|de\s+funcionamiento)\b/i,
    /\bpruebas\s+(?:funcionales?|de\s+funcionamiento)\s+(?:previas?\s+al\s+uso\s+)?(?:indica|debo|hay)\b/i,
    /\b(?:exhaustiv[oa]s?|complet[oa]s?)\b/i,
    /\b(?:all|every)\s+(?:tests?|checks?|steps?|controls?)\b/i,
    /\bcomplete\s+(?:list|checklist|procedure)\b/i
  ].freeze

  SAFETY_CRITICAL_PATTERNS = [
    /\b(?:detener|detenga|parar|pare|stop|prohibir|fuera\s+de\s+servicio)\b/i,
    /\b(?:falla|fallo|fallar|defecto|defectuosa?|mal\s+funcionamiento)\b/i,
    /\b(?:reparar|reparaci[oó]n|qui[eé]n\s+(?:puede|est[aá]\s+autorizado))\b/i
  ].freeze

  def initialize(entity_sources: [], question: nil)
    @entity_sources = Array(entity_sources).compact
    @question = question.to_s
  end

  def number_of_results
    return EXHAUSTIVE_CANDIDATES if exhaustive_query?

    if @entity_sources.empty?
      return MAX_RESULTS if schematic_block_query?

      return OPEN_RESULTS
    end

    return SAFETY_CRITICAL_RESULTS if safety_critical_query?

    photo_count = @entity_sources.count { |s| s == "image_upload" }
    doc_count   = @entity_sources.count { |s| s == "document" }

    if photo_count > 0 && doc_count == 0
      PHOTO_RESULTS
    else
      PINNED_DOCUMENT_RESULTS
    end
  end

  def number_of_reranked_results
    EXHAUSTIVE_RERANKED_RESULTS if exhaustive_query?
  end

  def exhaustive_query?
    EXHAUSTIVE_PATTERNS.any? { |pattern| @question.match?(pattern) }
  end

  def safety_critical_query?
    SAFETY_CRITICAL_PATTERNS.any? { |pattern| @question.match?(pattern) }
  end

  # A schematic designator (-PDCM, -PBCM, -PDCC, -J26…) together with a
  # connector/label/diagram keyword. Used to widen open-query recall so the
  # block→connector overview chunk lands in the generation window.
  SCHEMATIC_DESIGNATOR_PATTERN = /-[A-Z]{1,6}\d{0,3}\b/.freeze
  SCHEMATIC_KEYWORD_PATTERN = /\b(?:conector(?:es)?|borne(?:s)?|etiquetas?|texto\s+visible|esquema|bloque|se[ñn]al(?:es)?|plano|mazo(?:s)?|cable(?:s)?)\b/i.freeze

  def schematic_block_query?
    @question.match?(SCHEMATIC_DESIGNATOR_PATTERN) &&
      @question.match?(SCHEMATIC_KEYWORD_PATTERN)
  end
end
