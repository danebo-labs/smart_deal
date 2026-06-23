# frozen_string_literal: true

require "digest"
require "set"

# Parses a single Claude response for a file asset:
#   1. Extracts and validates the JSON from Claude's response.
#   2. Applies LambdaParityAliasFallback when the LLM returns empty aliases.
#   3. Prepends the identity header ([DOCUMENT:] / [SOURCE_URI:] / [SEARCH_ALIASES:])
#      to each chunk — identity is 100% Rails-injected; no dependency on in-body markers.
#   4. Writes each chunk as a .txt file PLUS a `<key>.metadata.json` sidecar to S3.
#   5. For BulkUploadAsset (AR): persists canonical_name, aliases, chunks_count,
#      chunks_s3_prefix, status, and broadcasts a Turbo replace.
#      For ChunkAsset (Struct): sets the same fields in-memory (no AR, no broadcast).
#
# Accepts two asset shapes via duck-typing:
#   BulkUploadAsset (ActiveRecord) — bulk ingestion path, responds to update! + broadcast_replace!
#   ChunkAsset (Struct)             — web custom chunking path
#
# @param ingestion_path [String] written to sidecar metadataAttributes["ingestion_path"].
#   "batch_v1"       = bulk path (default, backward-compatible)
#   "web_v1"         = web custom chunking (text/PDF/Office via SingleFileChunkingService)
#   "field_photo_v1" = web photo path (Sonnet + FieldPhotoPrompt, direct-API cost)
#   "manual_batch_v1" = PDF page batch path (bulk ZIP, or web long-manual Batch)
class BatchResultsParserService
  class ParseError < StandardError; end

  CHUNK_PREFIX_TPL = "bulk_chunks/%s/%s"
  MANUAL_BATCH_INGESTION_PATH = "manual_batch_v1"
  DOCUMENT_ALIAS_LIMIT = 15
  CHUNK_ALIAS_LIMIT    = 8
  FIELD_RECORD_TYPES = %w[
    MAINTENANCE_TASK INSPECTION_CHECK CERTIFICATION_REQUIREMENT FUNCTIONAL_TEST
    TROUBLESHOOTING_STEP FAULT_CONDITION REPAIR_ACTION STOP_WORK_CONDITION
    EMERGENCY_OR_RESCUE INSTALLATION_STEP COMMISSIONING_STEP MODERNIZATION_STEP
    SCHEMATIC_LABEL SAFETY_WARNING DOCUMENTATION_REQUIREMENT
  ].freeze
  FIELD_RECORD_REQUIRED_KEYS = %w[k h a r ev].freeze
  FIELD_RECORD_OPTIONAL_KEYS = %w[x sw ra u].freeze
  FIELD_RECORD_ALLOWED_KEYS = (FIELD_RECORD_REQUIRED_KEYS + FIELD_RECORD_OPTIONAL_KEYS).freeze
  CONDITIONAL_TRANSPORT_STOP_REGEX = /
    si\s+
    (?<trigger>[^.]{1,220}?\b(?:supera|excede|sobrepasa)\b[^.]{1,220}?)
    [,;]?\s+
    (?:la\s+)?(?:maquina|máquina|plataforma|equipo)\s+
    debe\s+
    (?<action>[^.]{1,220}?\b(?:levantarse|transportarse|levantado|levantada|transportado|transportada|transportar|levantar|no\s+operar|no\s+conducir)\b[^.]{0,220})
  /ix

  def initialize(s3_service: nil)
    @s3 = s3_service || S3DocumentsService.new
  end

  # @param asset         [BulkUploadAsset | ChunkAsset]
  # @param result        [Object, nil]  Anthropic batch result (.result.type, .result.message)
  # @param raw_json      [String, nil]  pre-parsed JSON string (web path — skips result unwrap)
  # @param ingestion_path [String]      "batch_v1" | "web_v1"
  # @return asset with parsed fields set
  # @raise [ParseError]
  def call(asset:, result: nil, raw_json: nil, ingestion_path: "batch_v1", account_id: nil, document_uid: nil)
    text = if raw_json
      raw_json
    else
      unless result.result.type.to_s == "succeeded"
        raise ParseError, "Result type '#{result.result.type}' for #{asset.filename}"
      end
      extract_text(result.result.message)
    end

    parsed  = parse_json(text)
    discard_unverifiable_field_records!(parsed, ingestion_path: ingestion_path)
    enrich_field_records!(parsed, ingestion_path: ingestion_path)
    validate!(parsed, asset, ingestion_path: ingestion_path)
    validate_account_scope!(account_id: account_id, document_uid: document_uid)

    chunks_prefix = chunks_prefix_for(asset, account_id: account_id, document_uid: document_uid)
    aliases       = sanitize_aliases(parsed["aliases"], limit: DOCUMENT_ALIAS_LIMIT)

    # Alias fallback: never write [SEARCH_ALIASES: ] empty even if LLM returns nothing.
    # Applies to both web and bulk paths.
    if aliases.empty?
      aliases = sanitize_aliases(
        LambdaParityAliasFallback.generate(asset.filename),
        limit: DOCUMENT_ALIAS_LIMIT
      )
    end

    write_chunks_to_s3(
      prefix:         chunks_prefix,
      chunks:         parsed["chunks"],
      asset:          asset,
      canonical_name: parsed["document_name"],
      aliases:        aliases,
      ingestion_path: ingestion_path,
      account_id:     account_id,
      document_uid:   document_uid
    )

    if asset.respond_to?(:update!)
      # BulkUploadAsset — ActiveRecord path
      asset.update!(
        canonical_name:   parsed["document_name"],
        aliases:          aliases,
        chunks_count:     parsed["chunks"].length,
        chunks_s3_prefix: chunks_prefix,
        status:           "parsed"
      )
      asset.broadcast_replace!
    else
      # ChunkAsset — in-memory struct, no AR
      asset.canonical_name    = parsed["document_name"]
      asset.aliases           = aliases
      asset.summary           = parsed["summary"].to_s.strip.presence
      asset.companion_offer   = parsed["companion_offer"].to_s.strip.presence
      asset.chunks_count      = parsed["chunks"].length
      asset.chunks_s3_prefix  = chunks_prefix
    end

    asset
  rescue ParseError => e
    if asset.respond_to?(:update_columns)
      asset.update_columns(status: "failed", error_message: e.message)
      asset.broadcast_replace!
    end
    raise
  end

  private

  def extract_text(message)
    content = message.respond_to?(:content) ? message.content : Array(message["content"])
    content.each do |block|
      type = block.respond_to?(:type) ? block.type : block["type"]
      return (block.respond_to?(:text) ? block.text : block["text"]) if type.to_s == "text"
    end
    raise ParseError, "No text block in Claude response"
  end

  def parse_json(text)
    LlmJsonParser.parse(text)
  rescue JSON::ParserError => e
    raise ParseError, "Invalid JSON from Claude: #{e.message}"
  end

  def validate!(parsed, asset, ingestion_path:)
    unless parsed.is_a?(Hash) &&
           parsed.key?("document_name") &&
           parsed.key?("chunks") &&
           parsed.key?("aliases")
      raise ParseError, "Missing required keys in Claude response for #{asset.filename}"
    end

    chunks = parsed["chunks"]
    raise ParseError, "No chunks in response for #{asset.filename}" if chunks.blank?
    return if ingestion_path == "field_photo_v1"

    chunks.each_with_index do |chunk, chunk_index|
      unless chunk.is_a?(Hash) && chunk["text"].to_s.present?
        raise ParseError, "Invalid chunk #{chunk_index} for #{asset.filename}"
      end
      unless chunk.key?("field_records") && chunk["field_records"].is_a?(Array)
        raise ParseError, "Missing field_records array in chunk #{chunk_index} for #{asset.filename}"
      end

      chunk["field_records"].each_with_index do |record, record_index|
        validate_field_record!(
          record,
          asset: asset,
          chunk_index: chunk_index,
          record_index: record_index
        )
      end
    end
  end

  def enrich_field_records!(parsed, ingestion_path:)
    return if ingestion_path == "field_photo_v1"

    Array(parsed["chunks"]).each do |chunk|
      next unless chunk.is_a?(Hash) && chunk["field_records"].is_a?(Array)

      deterministic_stop_work_records(chunk).each do |record|
        next if stop_work_equivalent_present?(chunk["field_records"], record)

        chunk["field_records"] << record
      end
    end
  end

  def discard_unverifiable_field_records!(parsed, ingestion_path:)
    return if ingestion_path == "field_photo_v1"

    Array(parsed["chunks"]).each_with_index do |chunk, chunk_index|
      next unless chunk.is_a?(Hash) && chunk["field_records"].is_a?(Array)

      chunk["field_records"] = chunk["field_records"].filter_map.with_index do |record, record_index|
        if unverifiable_non_stop_field_record?(record)
          Rails.logger.warn(
            "BatchResultsParserService: dropping field_record without evidence " \
            "in chunk #{chunk_index} field_record #{record_index}"
          )
          next
        end

        record
      end
    end
  end

  def unverifiable_non_stop_field_record?(record)
    return false unless record.is_a?(Hash)

    values = record.deep_stringify_keys
    record_type = values["k"].to_s
    return false unless FIELD_RECORD_TYPES.include?(record_type)
    return false if record_type == "STOP_WORK_CONDITION"

    !values.key?("ev") ||
      !values["ev"].is_a?(String) ||
      field_value(values["ev"]) == "DATA_NOT_AVAILABLE"
  end

  def deterministic_stop_work_records(chunk)
    text = chunk["text"].to_s
    searchable_text = text.gsub(/\s+/, " ")
    matches = searchable_text.scan(CONDITIONAL_TRANSPORT_STOP_REGEX)
    return [] if matches.empty?

    matches.filter_map do |trigger, action|
      trigger = field_value(trigger)
      action = field_value(action)
      evidence = conditional_transport_evidence(text)
      next if evidence == "DATA_NOT_AVAILABLE"

      {
        "k" => "STOP_WORK_CONDITION",
        "h" => semantic_heading(chunk),
        "a" => "Verificar condición límite documentada: #{trigger}",
        "r" => evidence,
        "ev" => evidence,
        "sw" => [ trigger, action ]
      }
    end
  end

  def conditional_transport_evidence(text)
    normalized = text.to_s.gsub(/\s+/, " ").strip
    match = normalized.match(
      /
        ((?:la\s+)?(?:máquina|maquina|plataforma|equipo)\s+
        debe\s+
        [^.]{0,320}\b(?:levantarse|transportarse|levantado|levantada|transportado|transportada|transportar|levantar|no\s+operar|no\s+conducir)\b
        [^.]{0,320})
      /ix
    )
    field_value(match && match[1])
  end

  def semantic_heading(chunk)
    text = chunk["text"].to_s
    heading = text[/^##\s+(.+)$/i, 1] ||
      text[/^\*\*Section:\*\*\s+(.+)$/i, 1] ||
      "Page #{chunk['page']}"
    field_value(heading)
  end

  def stop_work_equivalent_present?(records, candidate)
    candidate_tokens = semantic_token_set([ candidate["sw"], candidate["ev"] ].flatten.join(" "))
    Array(records).any? do |record|
      values = record.deep_stringify_keys
      next false unless values["k"] == "STOP_WORK_CONDITION"

      existing_tokens = semantic_token_set([ values["sw"], values["ev"] ].flatten.join(" "))
      (candidate_tokens & existing_tokens).size >= 3
    end
  end

  def normalize_semantic_text(text)
    I18n.transliterate(text.to_s.downcase).gsub(/\s+/, " ")
  end

  def semantic_token_set(text)
    normalize_semantic_text(text).scan(/[a-z0-9]{3,}/).to_set
  end

  def validate_field_record!(record, asset:, chunk_index:, record_index:)
    location = "chunk #{chunk_index} field_record #{record_index} for #{asset.filename}"
    raise ParseError, "Invalid #{location}" unless record.is_a?(Hash)

    values = record.deep_stringify_keys
    missing = FIELD_RECORD_REQUIRED_KEYS.reject { |key| values.key?(key) }
    raise ParseError, "Missing #{missing.join(', ')} in #{location}" if missing.any?

    unknown = values.keys - FIELD_RECORD_ALLOWED_KEYS
    raise ParseError, "Unknown #{unknown.join(', ')} in #{location}" if unknown.any?

    FIELD_RECORD_REQUIRED_KEYS.each do |key|
      unless values[key].is_a?(String) && values[key].present?
        raise ParseError, "Invalid #{key} in #{location}"
      end
    end

    FIELD_RECORD_OPTIONAL_KEYS.excluding("sw").each do |key|
      next unless values.key?(key)

      unless values[key].is_a?(String) && values[key].present?
        raise ParseError, "Invalid #{key} in #{location}"
      end
    end

    record_type = values["k"]
    unless FIELD_RECORD_TYPES.include?(record_type)
      raise ParseError, "Invalid k in #{location}"
    end

    stop_pair = values["sw"]
    if values.key?("sw")
      valid_pair = stop_pair.is_a?(Array) &&
        stop_pair.size == 2 &&
        stop_pair.all? do |value|
          value.is_a?(String) && value.present? && field_value(value) != "DATA_NOT_AVAILABLE"
        end
      raise ParseError, "Incomplete stop-work evidence pair in #{location}" unless valid_pair
      if record_type != "STOP_WORK_CONDITION"
        raise ParseError, "Unexpected sw outside STOP_WORK_CONDITION in #{location}"
      end
    elsif record_type == "STOP_WORK_CONDITION"
      raise ParseError, "STOP_WORK_CONDITION lacks evidence pair in #{location}"
    end
  end

  def write_chunks_to_s3(prefix:, chunks:, asset:, canonical_name:, aliases:, ingestion_path:, account_id:, document_uid:)
    original_uri = original_source_uri(asset)
    sidecar_json = sidecar_metadata(
      asset:          asset,
      canonical_name: canonical_name,
      aliases:        aliases,
      original_uri:   original_uri,
      ingestion_path: ingestion_path,
      account_id:     account_id,
      document_uid:   document_uid
    )
    delete_existing_chunks(prefix) if ingestion_path == MANUAL_BATCH_INGESTION_PATH

    page_ordinals = Hash.new(0)
    chunks.each_with_index do |chunk, idx|
      txt_key = "#{prefix}/#{chunk_filename(chunk, idx, ingestion_path: ingestion_path, page_ordinals: page_ordinals)}"
      chunk_aliases = sanitize_aliases(chunk["aliases"], limit: CHUNK_ALIAS_LIMIT)
      chunk_aliases = aliases.first(CHUNK_ALIAS_LIMIT) if chunk_aliases.empty?
      header = identity_header(asset: asset, aliases: chunk_aliases, original_uri: original_uri)
      body = append_field_records(chunk["text"], chunk["field_records"], page: chunk["page"])

      @s3.upload_text(txt_key, header + body)
      @s3.upload_text("#{txt_key}.metadata.json", sidecar_json)
    end
  end

  def chunk_filename(chunk, idx, ingestion_path:, page_ordinals:)
    return "chunk_#{idx}.txt" unless ingestion_path == MANUAL_BATCH_INGESTION_PATH

    page = chunk["page"].presence || "na"
    page_ordinals[page] += 1
    "chunk_p#{page}_#{page_ordinals[page]}.txt"
  end

  def chunks_prefix_for(_asset, account_id:, document_uid:)
    format(CHUNK_PREFIX_TPL, account_id, document_uid)
  end

  def delete_existing_chunks(prefix)
    @s3.delete_prefix(prefix) if @s3.respond_to?(:delete_prefix)
  rescue StandardError => e
    Rails.logger.warn("BatchResultsParserService: failed to clear #{prefix} before rewrite — #{e.message}")
  end

  def append_field_records(text, records, page:)
    rendered = Array(records).filter_map do |record|
      render_field_record(record, page: page) if record.is_a?(Hash)
    end
    return text.to_s if rendered.empty?

    "#{text.to_s.rstrip}\n\n# FIELD-SAFETY EVIDENCE RECORDS\n\n#{rendered.join("\n\n")}\n"
  end

  def render_field_record(record, page:)
    values = record.deep_stringify_keys
    record_type = allowlisted_value(values["k"], FIELD_RECORD_TYPES)
    source = field_value(values["h"])
    source = "Page #{page}" if source == "DATA_NOT_AVAILABLE" && page.present?
    stop_pair = Array(values["sw"])
    record_id = field_record_id(
      page: page,
      source: source,
      record_type: record_type,
      action: values["a"],
      expected_result: values["r"],
      evidence: values["ev"],
      stop_trigger: stop_pair[0],
      stop_action: stop_pair[1]
    )

    lines = [
      "FIELD_RECORD:",
      "RECORD_ID: #{record_id}",
      "SOURCE_SECTION_OR_PAGE: #{source}",
      "RECORD_TYPE: #{record_type}",
      "ACTION: #{field_value(values["a"])}",
      "EXPECTED_RESULT: #{field_value(values["r"])}"
    ]
    lines << "DETAILS: #{field_value(values['x'])}" if values["x"].present?
    if values["sw"].present?
      lines << "STOP_WORK_TRIGGER: #{field_value(values['sw'][0])}"
      lines << "STOP_WORK_REQUIRED_ACTION: #{field_value(values['sw'][1])}"
    end
    lines << "REPAIR_AUTHORITY: #{field_value(values['ra'])}" if values["ra"].present?
    lines << "UNCERTAINTY: #{field_value(values['u'])}" if values["u"].present?
    lines << "EVIDENCE: #{field_value(values['ev'])}"
    lines << "END_FIELD_RECORD"
    lines.join("\n")
  end

  # Append stop-work context only when present. This distinguishes sibling
  # safety records without changing historical IDs for every other record type.
  def field_record_id(page:, source:, record_type:, action:, expected_result:,
                      evidence:, stop_trigger: nil, stop_action: nil)
    fingerprint_parts = [
      page,
      source,
      record_type,
      field_value(action),
      field_value(expected_result),
      field_value(evidence)
    ]
    if stop_trigger.present? || stop_action.present?
      fingerprint_parts.push(field_value(stop_trigger), field_value(stop_action))
    end
    fingerprint = fingerprint_parts.join("\u001F")

    "FR-#{Digest::SHA256.hexdigest(fingerprint).first(16).upcase}"
  end

  def allowlisted_value(value, allowed)
    candidate = field_value(value)
    allowed.include?(candidate) ? candidate : "DATA_NOT_AVAILABLE"
  end

  def field_value(value)
    normalized = value.to_s.gsub(/\s+/, " ").strip
    normalized.presence || "DATA_NOT_AVAILABLE"
  end

  # Mirrors the legacy POST_CHUNKING Lambda contract so retrieval-side parsing
  # (bedrock/generation.txt STEP A/B + RULE 8, EntityExtractorService) is identical
  # for chunks produced by the batch path and chunks produced by the Bedrock-FM
  # parser path.
  def identity_header(asset:, aliases:, original_uri:)
    alias_line = sanitize_aliases(aliases, limit: CHUNK_ALIAS_LIMIT).join(", ")

    "[DOCUMENT: #{asset.filename}]\n" \
      "[SOURCE_URI: #{original_uri}]\n" \
      "[SEARCH_ALIASES: #{alias_line}]\n\n"
  end

  # Sidecar JSON consumed by the Bedrock S3 connector as `customMetadata` on the
  # resulting chunk. Keys are intentionally non-reserved (Bedrock owns x-amz-bedrock-kb-*).
  # `original_source_uri` is the seam retrieval filtering ORs alongside
  # `x-amz-bedrock-kb-source-uri` to make pin-based filters work for batch/web chunks.
  # `ingestion_path` distinguishes web_v1 (optimized) from batch_v1 (bulk) in telemetry.
  # `account_id` / `project_id` are reserved here as multi-tenant seams — absent today (MVP).
  def sidecar_metadata(asset:, canonical_name:, aliases:, original_uri:, ingestion_path:, account_id:, document_uid:)
    contract_version, prompt_fingerprint = contract_metadata(ingestion_path)

    JSON.generate(
      "metadataAttributes" => {
        "account_id"          => account_id.to_s,
        "document_id"         => document_uid.to_s,
        "original_source_uri" => original_uri,
        "original_filename"   => asset.filename,
        "canonical_name"      => canonical_name.to_s,
        "doc_sha256"          => asset.sha256.to_s,
        "ingestion_path"      => ingestion_path,
        "ingestion_contract_version" => contract_version,
        "prompt_fingerprint_sha256"  => prompt_fingerprint,
        "aliases"             => sanitize_aliases(aliases, limit: DOCUMENT_ALIAS_LIMIT)
      }
    )
  end

  def validate_account_scope!(account_id:, document_uid:)
    raise ParseError, "account_id is required before chunk writes" if account_id.blank?
    raise ParseError, "document_id is required before chunk writes" if document_uid.blank?
  end

  # The contract that produced this parse, derived from the ingestion path:
  # the photo path uses FieldPhotoPrompt's envelope; every other path uses the
  # BatchChunkingPrompt field_records contract.
  def contract_metadata(ingestion_path)
    if ingestion_path == "field_photo_v1"
      [ FieldPhotoPrompt::INGESTION_CONTRACT_VERSION, FieldPhotoPrompt.prompt_fingerprint_sha256 ]
    else
      [ BatchChunkingPrompt::INGESTION_CONTRACT_VERSION, BatchChunkingPrompt.prompt_fingerprint_sha256 ]
    end
  end

  def sanitize_aliases(values, limit:)
    seen = {}

    Array(values).filter_map do |value|
      alias_name = value.to_s.strip
      key = alias_name.downcase

      next unless alias_name.length.between?(2, 60)
      next if seen[key]
      next if alias_name.match?(/[|]|\*\*|##|⚠️|→|←|https?:\/\/|s3:\/\//)
      next if alias_name.count(" ") > 8

      seen[key] = true
      alias_name
    end.first(limit)
  end

  def original_source_uri(asset)
    "s3://#{kb_bucket}/#{asset.s3_key}"
  end

  def kb_bucket
    @kb_bucket ||= ENV["KNOWLEDGE_BASE_S3_BUCKET"].presence ||
                   Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
                   Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
                   "multimodal-source-destination"
  end
end
