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
#   - aliases:       union across all pages, deduped, preserving insertion order
#   - chunks:        concat of all pages' chunks in page-number order
#   - chunk["page"]: original 1-indexed page number (gaps allowed — NOT renumbered)
class ChunkMergerService
  # @param page_results [Array<Hash>]
  #   Each: { page_number: Integer, text: String (Claude JSON), usage:, model: String }
  # @return [String] merged JSON
  def self.merge(page_results)
    new(page_results).merge
  end

  def initialize(page_results)
    @page_results = page_results.sort_by { |r| r[:page_number] }
  end

  def merge
    raise ArgumentError, "No page results to merge" if @page_results.empty?

    parsed_pages = @page_results.map.with_index do |r, idx|
      parse_page(r[:text], idx, r[:page_number])
    end

    doc_name    = canonical_name(parsed_pages)
    all_aliases = parsed_pages.flat_map { |p| Array(p["aliases"]).map(&:to_s).map(&:strip) }
                               .reject(&:empty?)
                               .uniq

    all_chunks = parsed_pages.flat_map.with_index do |parsed, idx|
      orig_page = @page_results[idx][:page_number]
      Array(parsed["chunks"]).map do |chunk|
        chunk.merge("page" => (chunk["page"] || orig_page).to_i)
      end
    end

    JSON.generate({
      "document_name" => doc_name,
      "aliases"       => all_aliases,
      "chunks"        => all_chunks
    })
  end

  private

  # Canonical document_name selection:
  #   1. Use page 1's document_name if page 1 is in the result set and non-empty.
  #   2. Otherwise use the lowest page_number with a non-empty document_name.
  # Logs a warning when names differ across pages (drift indicates prompt inconsistency).
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

    name
  end

  def parse_page(text, idx, page_number)
    JSON.parse(text.to_s.strip)
  rescue JSON::ParserError => e
    Rails.logger.error("ChunkMergerService: JSON parse error page #{page_number} (idx #{idx}): #{e.message}")
    { "document_name" => "", "aliases" => [], "chunks" => [] }
  end
end
