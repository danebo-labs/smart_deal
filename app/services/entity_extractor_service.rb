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
  FABRICATED_URI_PATTERN = %r{\As3://(unknown|unknown-bucket|placeholder|no[_-]?bucket)/}i.freeze

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

    # Haiku often emits multiple doc_refs (different canonical_names / aspects)
    # for the SAME physical file. Collapse by source_uri so we persist exactly
    # one entity per physical document.
    doc_refs = collapse_doc_refs_by_source_uri(doc_refs)

    # When the KB returns multiple chunks, Haiku may emit multiple doc_refs.
    # Only the doc(s) that BEST MATCH the user's query should be persisted to
    # TechnicianDocument. Secondary results are added to the session for RAG
    # context but not written to the global document store.
    primary_names = primary_canonical_names(doc_refs, user_message)

    doc_refs.each do |ref|
      canonical = ref["canonical_name"]
      next if canonical.blank?

      aliases = Array(ref["aliases"])
      haiku_uri   = ref["source_uri"].to_s
      s3_from_ref = extract_filename_from_uri(ref["source_uri"])

      # Priority: physical identity (source_uri) > wa_filename > name/alias > oldest pending.
      # source_uri is the authoritative dedup key — two canonical_names referring
      # to the same s3_uri must collapse into the same session entity.
      existing_key = (real_s3_uri?(haiku_uri) && @session.find_entity_by_source_uri(haiku_uri)) ||
                     find_pending_entity_by_wa_filename(s3_from_ref) ||
                     @session.find_entity_by_name_or_alias(canonical) ||
                     aliases.lazy.filter_map { |a| @session.find_entity_by_name_or_alias(a) }.first ||
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

      # Session update: always propagate metadata/aliases.
      if existing_key
        promote_pending_entity(existing_key, canonical, aliases, metadata)
      else
        @session.add_entity_with_aliases(canonical, aliases.uniq, metadata)
      end

      # TechnicianDocument persistence: ONLY for the primary doc(s) of THIS
      # query, regardless of whether the entity was already in the session.
      # Without this gate, a secondary doc that landed in the session on a
      # prior query would get promoted into TechnicianDocument on the next
      # query (because existing_key would be set), bypassing the primary filter.
      if primary_names.include?(canonical) || primary_names.empty?
        persist_to_technician_documents(canonical, metadata)
      else
        Rails.logger.info("EntityExtractor: session-only (secondary KB result): #{canonical.inspect}")
      end

      enrich_kb_document(canonical, metadata)
    end
  end

  # Returns the set of canonical_names that correspond to the PRIMARY document(s)
  # for this query — those whose canonical_name or aliases best match the query.
  #
  # Uses canonical_name (always present) instead of source_uri (may be unresolved
  # when Bedrock returns 0 citations and backfill cannot run).
  #
  # Scoring: count of distinct query words (5+ chars) found in the doc's combined
  # text (canonical_name + all aliases). Docs at max score are primary.
  # Returns empty Set (= persist all) when scoring cannot discriminate.
  def primary_canonical_names(doc_refs, user_message)
    return Set.new if doc_refs.size <= 1

    query_words = user_message.to_s.downcase.scan(/[a-z]{5,}/).uniq

    # Can't discriminate with no meaningful query terms — treat all as primary.
    return Set.new if query_words.empty?

    scored = doc_refs.map do |ref|
      doc_text = ([ ref["canonical_name"] ] + Array(ref["aliases"])).join(" ").downcase
      score    = query_words.count { |w| doc_text.include?(w) }
      [ ref["canonical_name"].to_s, score ]
    end

    max_score = scored.map(&:last).max

    # All docs score the same → can't discriminate → treat all as primary.
    return Set.new if scored.map(&:last).uniq.size == 1

    Set.new(scored.select { |_, s| s == max_score }.map(&:first))
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

  # Per-query enrichment driven by Haiku's <DOC_REFS>. `display_name` is only
  # (re)assigned while it still looks like the auto-assigned stem placeholder
  # (display_name_promotable? always returns true — canonical always wins).
  # New canonicals from Haiku overwrite display_name; prior display_name is
  # kept in aliases so the RAG resolver still recognises it on future queries.
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
    Rails.logger.warn("EntityExtractor: failed to enrich kb_document: #{e.message}")
  end

  def real_s3_uri?(uri)
    return false unless uri.present? &&
                        uri.start_with?("s3://") &&
                        !uri.match?(FABRICATED_URI_PATTERN) &&
                        uri != "PIPELINE_INJECTED"

    # Real S3 objects always have a file extension (e.g. .pdf, .jpeg).
    # Haiku sometimes constructs credible-looking URIs using the user's query as
    # the filename with no extension — this catches that fabrication pattern.
    File.extname(File.basename(uri)).present?
  end

  # Collapses doc_refs that share the same source_uri into a single ref.
  # Haiku emits N canonical_names for the same physical file; after backfill
  # they all have the same source_uri → they must become one entity, with
  # aliases merged (and discarded canonical_names added as aliases).
  # Refs without a resolvable source_uri are passed through unchanged.
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

  # Enriches doc_refs in-place: for each ref missing a real S3 URI, finds a matching
  # citation from Bedrock's raw response and uses its location URI.
  # This covers batch-indexed documents where Haiku can't reliably extract the URI,
  # including files where PIPELINE_INJECTED prevents filename injection into the chunk.
  #
  # Matching strategy (ordered by precision):
  #   1. S3 filename contains canonical name or alias (original behaviour)
  #   2. Chunk content contains canonical name or alias (handles PIPELINE_INJECTED)
  #   3. Single doc_ref + single citation → unambiguous match, assign directly
  def backfill_source_uris_from_citations(doc_refs, all_retrieved)
    return if all_retrieved.blank?

    unique_uris = all_retrieved.filter_map { |c| citation_source_uri(c) }.uniq

    # Strong signal: ALL citations point to the same physical document, so every
    # doc_ref (regardless of how Haiku named it) must be about that file. This
    # catches the common case where Haiku invents multiple canonical_names for
    # a single uploaded image/PDF.
    if unique_uris.size == 1
      doc_refs.each do |ref|
        ref["source_uri"] = unique_uris.first unless real_s3_uri?(ref["source_uri"].to_s)
      end
      return
    end

    # Fast path: 1 doc_ref, 1 citation — unambiguous, no matching required.
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

        # 1. S3 filename ↔ canonical/alias (filename from Bedrock metadata, reliable)
        filename.include?(canonical_d.first(20)) ||
          aliases_d.any? { |a| filename.include?(a.first(20)) } ||
          # 2. Chunk content ↔ canonical/alias (fallback; content is pipeline-injected and may be unreliable)
          chunk_content.include?(canonical_d) ||
          aliases_d.any? { |a| a.length >= 5 && chunk_content.include?(a) }
      end

      ref["source_uri"] = citation_source_uri(matching) if matching
    end
  end

  # Returns the AUTHORITATIVE s3_uri for a Bedrock citation.
  # Priority: Bedrock response metadata > Bedrock response location.
  # Never uses URIs extracted from chunk content — the pipeline MLM sometimes
  # injects "PIPELINE_INJECTED" placeholders into the text, but the Bedrock
  # response metadata ALWAYS carries the true S3 URI.
  def citation_source_uri(citation)
    return nil if citation.blank?
    meta = citation[:metadata] || citation["metadata"] || {}
    (meta["x-amz-bedrock-kb-source-uri"] || meta[:"x-amz-bedrock-kb-source-uri"]).to_s.presence ||
      citation.dig(:location, :uri).presence ||
      citation.dig("location", "uri").presence
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
