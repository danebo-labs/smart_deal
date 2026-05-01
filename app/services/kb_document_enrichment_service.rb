# frozen_string_literal: true

# Enriches the global KbDocument catalog with canonical names + aliases that
# Haiku discovers in <DOC_REFS>. Does NOT touch ConversationSession or
# TechnicianDocument — those are user-driven by the pin/unpin UI now.
#
# Called once per query from RagController#ask, with the doc_refs and raw
# retrieved citations from BedrockRagService.
class KbDocumentEnrichmentService
  FABRICATED_URI_PATTERN = %r{\As3://(unknown|unknown-bucket|placeholder|no[_-]?bucket)/}i.freeze

  # @param doc_refs [Array<Hash>, nil] Haiku <DOC_REFS> JSON (BedrockRagService parses it)
  # @param all_retrieved [Array<Hash>] raw Bedrock citations (with metadata + location)
  def call(doc_refs:, all_retrieved: [])
    return if doc_refs.blank?

    refs = doc_refs.dup
    backfill_source_uris_from_citations(refs, Array(all_retrieved))
    refs = collapse_doc_refs_by_source_uri(refs)

    refs.each do |ref|
      canonical = ref["canonical_name"].to_s.strip
      next if canonical.blank?

      aliases = Array(ref["aliases"]).map { |a| a.to_s.strip }.compact_blank.uniq
      enrich_kb_document(canonical, "source_uri" => ref["source_uri"], "aliases" => aliases)
    end
  rescue StandardError => e
    Rails.logger.warn("KbDocumentEnrichmentService: failed: #{e.message}")
  end

  private

  def enrich_kb_document(canonical, metadata)
    source_uri = metadata["source_uri"]
    return if source_uri.blank?

    s3_key = KbDocument.object_key_for_match(source_uri)
    return if s3_key.blank?

    kb_doc = KbDocument.find_by(s3_key: s3_key)
    return unless kb_doc

    prior_display_name = kb_doc.display_name.presence
    kb_doc.display_name = canonical if canonical.present?

    kb_doc.aliases = (Array(kb_doc.aliases) + [ prior_display_name ] + Array(metadata["aliases"]))
                       .map { |a| a.to_s.strip }
                       .compact_blank
                       .reject { |a| a.casecmp?(kb_doc.display_name.to_s) }
                       .uniq
                       .first(15)
    kb_doc.save! if kb_doc.changed?
  rescue StandardError => e
    Rails.logger.warn("KbDocumentEnrichment: failed to enrich kb_document: #{e.message}")
  end

  def real_s3_uri?(uri)
    return false unless uri.present? &&
                        uri.start_with?("s3://") &&
                        !uri.match?(FABRICATED_URI_PATTERN) &&
                        uri != "PIPELINE_INJECTED"

    File.extname(File.basename(uri)).present?
  end

  def collapse_doc_refs_by_source_uri(doc_refs)
    with_uri, without_uri = doc_refs.partition { |r| real_s3_uri?(r["source_uri"].to_s) }

    merged = with_uri.group_by { |r| r["source_uri"] }.map do |_uri, group|
      primary = group.first.dup
      extra_aliases = group.drop(1).flat_map do |r|
        [ r["canonical_name"] ].compact + Array(r["aliases"])
      end
      primary["aliases"] = (Array(primary["aliases"]) + extra_aliases).map(&:to_s).uniq
      primary
    end

    merged + without_uri
  end

  def backfill_source_uris_from_citations(doc_refs, all_retrieved)
    return if all_retrieved.blank?

    unique_uris = all_retrieved.filter_map { |c| citation_source_uri(c) }.uniq

    if unique_uris.size == 1
      doc_refs.each do |ref|
        ref["source_uri"] = unique_uris.first unless real_s3_uri?(ref["source_uri"].to_s)
      end
      return
    end

    if doc_refs.size == 1 && all_retrieved.size == 1
      ref = doc_refs.first
      unless real_s3_uri?(ref["source_uri"].to_s)
        uri = citation_source_uri(all_retrieved.first)
        ref["source_uri"] = uri if uri.present?
      end
      return
    end

    doc_refs.each do |ref|
      next if real_s3_uri?(ref["source_uri"].to_s)

      canonical_d = ref["canonical_name"].to_s.downcase
      aliases_d   = Array(ref["aliases"]).map { |a| a.to_s.downcase }

      matching = all_retrieved.find do |c|
        citation_uri = citation_source_uri(c).to_s
        next false if citation_uri.blank?

        filename      = File.basename(citation_uri, ".*").downcase
        chunk_content = c[:content].to_s.downcase

        filename.include?(canonical_d.first(20)) ||
          aliases_d.any? { |a| filename.include?(a.first(20)) } ||
          chunk_content.include?(canonical_d) ||
          aliases_d.any? { |a| a.length >= 5 && chunk_content.include?(a) }
      end

      ref["source_uri"] = citation_source_uri(matching) if matching
    end
  end

  def citation_source_uri(citation)
    return nil if citation.blank?
    meta = citation[:metadata] || citation["metadata"] || {}
    (meta["x-amz-bedrock-kb-source-uri"] || meta[:"x-amz-bedrock-kb-source-uri"]).to_s.presence ||
      citation.dig(:location, :uri).presence ||
      citation.dig("location", "uri").presence
  end
end
