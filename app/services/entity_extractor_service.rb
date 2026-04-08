# frozen_string_literal: true

# Registers document entities and aliases on the ConversationSession.
#
# Primary path (RULE 8): uses doc_refs from Haiku's <DOC_REFS> JSON block,
#   already parsed by BedrockRagService.
#
# Fallback path: when doc_refs is nil, registers entities using filenames
#   from numbered citations only. NO regex parsing of chunk content.
class EntityExtractorService
  FILENAME_PATTERN       = /\b[\w\-_.]+\.(?:pdf|jpe?g|png|gif|webp|txt|md|docx?|xlsx?|csv|pptx?)\b/i.freeze
  NO_RESULTS_PATTERN     = /\A(No se encontró información|No information was found)/i.freeze
  FABRICATED_URI_PATTERN = %r{\As3://(unknown|placeholder|no[_-]?bucket)}i.freeze

  def initialize(session)
    @session = session
  end

  # @param numbered_citations [Array] hashes with :filename, :content, :location, :metadata
  # @param user_message [String]
  # @param answer [String, nil]
  # @param all_retrieved [Array] raw Bedrock citations — used to backfill source_uri for batch docs
  # @param doc_refs [Array, nil] from BedrockRagService RULE 8
  def extract_and_update(numbered_citations, user_message:, answer: nil, all_retrieved: [], doc_refs: nil)
    return unless @session

    if doc_refs.present?
      register_from_doc_refs(doc_refs, user_message, answer, all_retrieved)
    else
      register_from_citation_filenames(numbered_citations, user_message, answer)
    end
  end

  private

  def register_from_doc_refs(doc_refs, user_message, answer = nil, all_retrieved = [])
    backfill_source_uris_from_citations(doc_refs, all_retrieved)

    doc_refs.each do |ref|
      canonical = ref["canonical_name"]
      next if canonical.blank?

      aliases = Array(ref["aliases"])
      haiku_uri   = ref["source_uri"].to_s
      s3_from_ref = extract_filename_from_uri(ref["source_uri"])

      existing_key = find_pending_entity_by_wa_filename(s3_from_ref) ||
                     @session.find_entity_by_name_or_alias(canonical) ||
                     find_oldest_pending_entity
      existing_uri = existing_key && @session.active_entities.dig(existing_key, "source_uri")
      resolved_uri = real_s3_uri?(haiku_uri) ? haiku_uri : (existing_uri.presence || haiku_uri.presence)

      # Haiku often omits source_uri in <DOC_REFS>; basename must come from resolved session URI.
      s3_filename = s3_from_ref.presence || extract_filename_from_uri(resolved_uri)
      aliases << s3_filename if s3_filename.present? && s3_filename != "unknown"

      metadata = {
        "source"               => "doc_refs_rule8",
        "source_uri"           => resolved_uri,
        "doc_type"             => ref["doc_type"],
        "wa_filename"          => s3_filename,
        "extraction_method"    => "haiku_doc_refs",
        "detected_from"        => user_message.to_s.truncate(100),
        "first_answer_summary" => answer.to_s.first(200).presence,
        "aliases"              => aliases.uniq
      }.compact

      Rails.logger.info("EntityExtractor: doc_ref canonical=#{canonical.inspect} source_uri=#{resolved_uri.inspect} s3_filename=#{s3_filename.inspect} matched_key=#{existing_key.inspect}")

      if existing_key
        promote_pending_entity(existing_key, canonical, aliases, metadata)
        persist_to_technician_documents(canonical, metadata)
      else
        @session.add_entity_with_aliases(canonical, aliases.uniq, metadata)
        persist_to_technician_documents(canonical, metadata)
      end
    end
  end

  # Finds a placeholder entity whose wa_filename matches the doc_ref's source file.
  def find_pending_entity_by_wa_filename(s3_filename)
    return nil if s3_filename.blank?
    return nil unless looks_like_filename?(s3_filename)

    stem = File.basename(s3_filename, ".*")
    @session.active_entities.each do |key, meta|
      wa = meta["wa_filename"].to_s
      return key if wa == s3_filename || wa == stem || key == stem
    end
    nil
  end

  PROMOTABLE_METHODS = %w[pending_first_query chunk_aliases].freeze

  # Fallback: find the oldest promotable entity (not yet enriched by Haiku).
  def find_oldest_pending_entity
    @session.active_entities
      .select { |_, meta| meta["extraction_method"].in?(PROMOTABLE_METHODS) }
      .min_by { |_, meta| meta["added_at"].to_s }
      &.first
  end

  def looks_like_filename?(str)
    str.match?(/\.\w{2,5}\z/)
  end

  # Replaces the placeholder entity with a semantically-named one,
  # preserving the wa_filename linkage and merging aliases.
  def promote_pending_entity(old_key, canonical, new_aliases, metadata)
    entities = @session.active_entities.dup
    old_meta = entities.delete(old_key) || {}

    merged_aliases = ((old_meta["aliases"] || []) + new_aliases).map(&:to_s).uniq
    merged_aliases << old_meta["wa_filename"] if old_meta["wa_filename"].present?

    # Preserve original wa_filename when Haiku invents a URI with a .pdf/.jpeg basename,
    # or when the stored name is a generated wa_* upload id.
    if old_meta["wa_filename"].present?
      old_wa = old_meta["wa_filename"].to_s
      new_wa = metadata["wa_filename"].to_s
      preserve = old_wa.start_with?("wa_") || !looks_like_filename?(new_wa)
      metadata = metadata.merge("wa_filename" => old_meta["wa_filename"]) if preserve
    end

    # Preserve real source_uri from the original entity when incoming one is fabricated/missing.
    if old_meta["source_uri"].present? && old_meta["source_uri"].start_with?("s3://")
      metadata = metadata.merge("source_uri" => old_meta["source_uri"]) unless real_s3_uri?(metadata["source_uri"])
    end

    entities[canonical] = old_meta.merge(metadata).merge(
      "canonical_name" => canonical,
      "aliases"        => merged_aliases
    )

    @session.update!(active_entities: entities)
  end

  def register_from_citation_filenames(numbered_citations, user_message, answer)
    Array(numbered_citations).each do |citation|
      filename = (citation[:filename] || citation["filename"]).to_s.strip
      next if filename.blank? || filename.casecmp?("Document")
      next if @session.find_entity_by_name_or_alias(filename)

      @session.add_entity(filename, {
        "source"            => "citation_filename_fallback",
        "extraction_method" => "filename_only",
        "detected_from"     => user_message.to_s.truncate(100)
      })
    end

    return if Array(numbered_citations).any?
    return unless valid_answer?(answer)

    filenames_from_text(user_message).each do |filename|
      next if @session.find_entity_by_name_or_alias(filename)
      @session.add_entity(filename, {
        "source"            => "user_message_filename",
        "extraction_method" => "filename_from_text",
        "detected_from"     => user_message.to_s.truncate(100)
      })
    end
  end

  def persist_to_technician_documents(canonical, metadata)
    return unless @session

    TechnicianDocument.upsert_from_entity(
      identifier:     @session.identifier,
      channel:        @session.channel,
      canonical_name: canonical,
      metadata:       metadata
    )
  rescue StandardError => e
    Rails.logger.warn("EntityExtractor: failed to persist technician doc: #{e.message}")
  end

  def real_s3_uri?(uri)
    uri.present? &&
      uri.start_with?("s3://") &&
      !uri.match?(FABRICATED_URI_PATTERN) &&
      uri != "PIPELINE_INJECTED"
  end

  # Enriches doc_refs in-place: for each ref missing a real S3 URI, finds a matching
  # citation from Bedrock's raw response and uses its location URI.
  # This covers batch-indexed documents where Haiku can't reliably extract the URI.
  def backfill_source_uris_from_citations(doc_refs, all_retrieved)
    return if all_retrieved.blank?

    doc_refs.each do |ref|
      next if real_s3_uri?(ref["source_uri"].to_s)

      matching = all_retrieved.find do |c|
        citation_uri = c.dig(:location, :uri).to_s
        next false if citation_uri.blank?

        filename = File.basename(citation_uri, ".*").downcase
        canonical_lower = ref["canonical_name"].to_s.downcase.first(20)
        filename.include?(canonical_lower) ||
          Array(ref["aliases"]).any? { |a| filename.include?(a.to_s.downcase.first(20)) }
      end

      ref["source_uri"] = matching.dig(:location, :uri) if matching
    end
  end

  def extract_filename_from_uri(uri)
    return nil if uri.blank?
    File.basename(uri.to_s)
  end

  def filenames_from_text(text)
    text.to_s.scan(FILENAME_PATTERN)
      .map(&:strip)
      .compact_blank
      .reject { |f| f.casecmp?("Document") }
      .uniq
  end

  def valid_answer?(answer)
    answer.present? && !answer.to_s.match?(NO_RESULTS_PATTERN)
  end
end
