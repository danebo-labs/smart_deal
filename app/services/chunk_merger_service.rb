# frozen_string_literal: true

# Merges N per-segment Claude responses from a single file into one canonical
# JSON string consumable by BatchResultsParserService.
#
# Today's use case: pages of a pdf_mixed document (one Claude call per page).
# The merger pattern is intentionally generic — it applies to any future multi-call
# split (text windows, large office documents, etc.); extend `part_index` alongside
# `page_number` when those cases arise.
#
# Contract:
#   - document_name: canonical rule — page 1's name if page 1 is in the result set
#     and its document_name is non-empty; otherwise the lowest page_number present
#     with a non-empty document_name. Drift across pages triggers a warn log.
#   - document_name_consensus: false when no name holds a majority across pages
#     (a multi-section compendium). Consumers fall back to the uploaded filename.
#   - aliases:       document-level union, deduped and capped
#   - chunks:        concat of all pages' chunks in page-number order
#   - chunk aliases: page/chunk-specific aliases, capped for discriminative retrieval
#   - chunk["page"]: original 1-indexed page number (gaps allowed — NOT renumbered)
#   - section_identity: the brand/controller family a divider page declares
#     (field_records_v7) is carried forward, in page order, into every following
#     page's chunk aliases until another page declares a new one.
#   - section_path: [section_identity] on every chunk that carries a
#     section_identity (field_records_v8, Fase 4). Single-element today —
#     section_identity == section_path.first is the retrocompatibility
#     invariant a deeper path would still have to hold.
#   - topology_edges: a page's TopologyEdgeDeriver output (threaded in on
#     each page_result's :topology_edges, empty/absent when
#     IngestionLayoutFlag is off) lands on that page's FIRST surviving chunk
#     only — an edge lives in exactly one chunk body, never duplicated
#     across a page's other chunks.
class ChunkMergerService
  DOCUMENT_ALIAS_LIMIT = 15
  CHUNK_ALIAS_LIMIT    = 8
  SECTION_IDENTITY_MAX_CHARS = 60
  DOCUMENT_IDENTIFICATION_S0_PATTERN = /\A\s*#*\s*S0\s*[—–-]\s*DOCUMENT IDENTIFICATION\b/i

  # S0-style marker surfaced to Haiku when a page could not be fully extracted.
  # %{page} is interpolated with the 1-indexed page number.
  DEGRADATION_MARKER = \
    "# S0 - EXTRACCION PARCIAL\n" \
    "Esta pagina (p%<page>d) no se proceso por completo durante la ingesta " \
    "(salida truncada o ilegible). REQUIRES_FIELD_VERIFICATION. " \
    "No fue indexada completa: vuelve a subir el archivo o solicita reprocesar esta pagina."

  # Used when the anchor page is degraded and emits no summary/companion_offer
  # (e.g. truncated output, parse failure, or CONTENT_PAGE sent as anchor by mistake).
  FALLBACK_COMPANION_OFFER = "Pregúntame lo que necesites — estoy aquí para lo que sea."

  # @param page_results [Array<Hash>]
  #   Each: { page_number: Integer, text: String (Claude JSON), stop_reason: String|nil, usage:, model: String }
  # @return [String] merged JSON (backward-compatible)
  def self.merge(page_results)
    merge_with_report(page_results)[:json]
  end

  # @return [Hash] { json: String, degraded_pages: Array<Integer> }
  def self.merge_with_report(page_results)
    new(page_results).merge_with_report
  end

  def initialize(page_results)
    @page_results = page_results.sort_by { |r| r[:page_number] }
  end

  def merge_with_report
    raise ArgumentError, "No page results to merge" if @page_results.empty?

    degraded_pages = []

    parsed_pages = @page_results.map.with_index do |r, idx|
      parsed, degraded = parse_page_result(r, idx)
      degraded_pages << r[:page_number] if degraded
      parsed
    end

    doc_name, chosen_idx = canonical_name(parsed_pages)
    document_aliases = sanitize_aliases(
      parsed_pages.flat_map { |page| Array(page["aliases"]) },
      limit: DOCUMENT_ALIAS_LIMIT
    )

    anchor_page_number = @page_results.first[:page_number]

    section_identity = nil

    all_chunks = parsed_pages.flat_map.with_index do |parsed, idx|
      orig_page = @page_results[idx][:page_number]
      page_aliases = sanitize_aliases(parsed["aliases"], limit: CHUNK_ALIAS_LIMIT)
      section_identity = declared_section_identity(parsed) || section_identity
      page_edges = Array(@page_results[idx][:topology_edges])
      edges_attached = false

      page_chunks = Array(parsed["chunks"])

      page_chunks.filter_map do |chunk|
        next if page_chunks.size > 1 &&
                stray_content_page_s0?(chunk, page_number: orig_page, anchor_page_number: anchor_page_number)

        chunk_aliases = sanitize_aliases(chunk["aliases"], limit: CHUNK_ALIAS_LIMIT)
        merged = chunk.merge(
          "page" => (chunk["page"] || orig_page).to_i,
          "aliases" => with_section_identity(chunk_aliases.presence || page_aliases, section_identity)
        )
        merged["section_identity"] = section_identity if section_identity.present?
        merged["section_path"] = [ section_identity ] if section_identity.present?
        if page_edges.present? && !edges_attached
          merged["topology_edges"] = page_edges
          edges_attached = true
        end
        merged
      end
    end

    anchor_page  = chosen_idx ? parsed_pages[chosen_idx] : nil
    raw_summary  = anchor_page&.dig("summary").to_s.presence
    raw_offer    = anchor_page&.dig("companion_offer").to_s.presence

    if raw_summary.nil?
      Rails.logger.warn(
        "ChunkMergerService: anchor page (idx=#{chosen_idx}) has no summary — using deterministic fallback"
      )
    end

    json = JSON.generate({
      "document_name"   => doc_name,
      "document_name_consensus" => document_name_consensus?(parsed_pages),
      "aliases"         => document_aliases,
      "summary"         => raw_summary || fallback_summary(doc_name),
      "companion_offer" => raw_offer   || FALLBACK_COMPANION_OFFER,
      "chunks"          => all_chunks
    })

    { json: json, degraded_pages: degraded_pages }
  end

  private

  def fallback_summary(document_name)
    name = document_name.to_s.strip
    name.present? ? "#{name}." : "Documento procesado y listo para consultas técnicas."
  end

  def sanitize_aliases(values, limit:)
    seen = {}

    Array(values).filter_map do |value|
      alias_name = value.to_s.strip
      next if alias_name.blank? || seen[alias_name.downcase]

      seen[alias_name.downcase] = true
      alias_name
    end.first(limit)
  end

  # The brand/controller family this page declares (field_records_v7), or nil.
  # A long value is a sign the model wrote prose instead of a section label, so it
  # is dropped rather than propagated to every following page.
  def declared_section_identity(parsed)
    value = parsed["section_identity"].to_s.strip
    return nil if value.blank? || value.length > SECTION_IDENTITY_MAX_CHARS

    value
  end

  # Section identity leads the alias list: it is the term the page itself never
  # prints, so it must survive CHUNK_ALIAS_LIMIT. Pages that already name the
  # brand are left untouched.
  def with_section_identity(aliases, section_identity)
    return aliases if section_identity.blank?
    return aliases if aliases.any? { |a| a.casecmp?(section_identity) }

    sanitize_aliases([ section_identity, *aliases ], limit: CHUNK_ALIAS_LIMIT)
  end

  # Only applied when the page has other chunks. A brand/section divider page
  # legitimately produces a single identification-shaped chunk, and that chunk holds
  # the only occurrence of the manufacturer name in the whole document — dropping it
  # would delete the page from the index entirely.
  def stray_content_page_s0?(chunk, page_number:, anchor_page_number:)
    page_number != anchor_page_number &&
      chunk.is_a?(Hash) &&
      chunk["text"].to_s.match?(DOCUMENT_IDENTIFICATION_S0_PATTERN)
  end

  # Returns [parsed_hash, degraded_boolean].
  # Three cases:
  #   - parse OK, not truncated  → normal parsed hash, not degraded
  #   - parse OK, max_tokens     → parsed chunks + marker appended, degraded
  #   - parse fails              → marker-only hash, degraded
  def parse_page_result(r, idx)
    page_number = r[:page_number]
    text        = r[:text].to_s.strip
    stop_reason = r[:stop_reason]

    parsed = LlmJsonParser.parse(text)

    if stop_reason == "max_tokens"
      marker  = degradation_marker_chunk(page_number)
      patched = parsed.merge("chunks" => Array(parsed["chunks"]) + [ marker ])
      [ patched, true ]
    else
      [ parsed, false ]
    end
  rescue JSON::ParserError => e
    Rails.logger.error("ChunkMergerService: JSON parse error page #{page_number} (idx #{idx}): #{e.message}")
    marker = degradation_marker_chunk(page_number)
    [ { "document_name" => "", "aliases" => [], "chunks" => [ marker ] }, true ]
  end

  def degradation_marker_chunk(page_number)
    {
      "text" => format(DEGRADATION_MARKER, page: page_number),
      "page" => page_number,
      "field_records" => []
    }
  end

  # True when a majority of pages agree on the same document_name.
  #
  # A compendium (one manufacturer or board per section) has no such majority: every
  # page names its own board, so no page name can speak for the file. Callers use this
  # to fall back to the uploaded filename instead of labelling all 98 pages with the
  # board that happened to sit on the anchor page. Minor drift on a single-topic manual
  # still has a clear majority and keeps the page-derived name.
  def document_name_consensus?(parsed_pages)
    names = parsed_pages.filter_map { |page| page["document_name"].to_s.strip.presence }
    return true if names.empty?

    names.tally.values.max * 2 > names.size
  end

  # Canonical document_name selection:
  #   1. Use page 1's document_name if page 1 is in the result set and non-empty.
  #   2. Otherwise use the lowest page_number with a non-empty document_name.
  # Logs a warning when names differ across pages (drift indicates prompt inconsistency).
  # Returns [name, chosen_idx] so callers can also extract summary/companion_offer from the anchor.
  def canonical_name(parsed_pages)
    page_one_idx = @page_results.index { |r| r[:page_number] == 1 }
    chosen_idx   = if page_one_idx && parsed_pages[page_one_idx]["document_name"].to_s.presence
      page_one_idx
    else
      parsed_pages.each_index.find { |i| parsed_pages[i]["document_name"].to_s.presence }
    end

    name = chosen_idx ? parsed_pages[chosen_idx]["document_name"].to_s : "Unknown Document"

    names = parsed_pages.map { |p| p["document_name"].to_s.presence }.compact.uniq
    if names.size > 1
      Rails.logger.warn(
        "ChunkMergerService: document_name drift across pages — #{names.inspect}; " \
        "using #{name.inspect} (page_one_idx=#{page_one_idx.inspect})"
      )
    end

    [ name, chosen_idx ]
  end
end
