# frozen_string_literal: true

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
#   "batch_v1" = bulk path (default, backward-compatible)
#   "web_v1"   = web custom chunking path
class BatchResultsParserService
  class ParseError < StandardError; end

  CHUNK_PREFIX_TPL = "bulk_chunks/%s/%s"

  def initialize(s3_service: nil)
    @s3 = s3_service || S3DocumentsService.new
  end

  # @param asset         [BulkUploadAsset | ChunkAsset]
  # @param result        [Object, nil]  Anthropic batch result (.result.type, .result.message)
  # @param raw_json      [String, nil]  pre-parsed JSON string (web path — skips result unwrap)
  # @param ingestion_path [String]      "batch_v1" | "web_v1"
  # @return asset with parsed fields set
  # @raise [ParseError]
  def call(asset:, result: nil, raw_json: nil, ingestion_path: "batch_v1")
    text = if raw_json
      raw_json
    else
      unless result.result.type.to_s == "succeeded"
        raise ParseError, "Result type '#{result.result.type}' for #{asset.filename}"
      end
      extract_text(result.result.message)
    end

    parsed  = parse_json(text)
    validate!(parsed, asset)

    date_prefix   = Date.current.iso8601
    chunks_prefix = format(CHUNK_PREFIX_TPL, date_prefix, asset.sha256)
    aliases       = Array(parsed["aliases"])

    # Alias fallback: never write [SEARCH_ALIASES: ] empty even if LLM returns nothing.
    # Applies to both web and bulk paths.
    aliases = LambdaParityAliasFallback.generate(asset.filename) if aliases.all?(&:blank?)

    write_chunks_to_s3(
      prefix:         chunks_prefix,
      chunks:         parsed["chunks"],
      asset:          asset,
      canonical_name: parsed["document_name"],
      aliases:        aliases,
      ingestion_path: ingestion_path
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

  def normalize_json_text(text)
    s = text.to_s.strip
    return s unless s.start_with?("```")

    s.sub(/\A```(?:json)?\s*\n?/i, "").sub(/\n?```\s*\z/, "").strip
  end

  def parse_json(text)
    JSON.parse(normalize_json_text(text))
  rescue JSON::ParserError => e
    raise ParseError, "Invalid JSON from Claude: #{e.message}"
  end

  def validate!(parsed, asset)
    unless parsed.is_a?(Hash) &&
           parsed.key?("document_name") &&
           parsed.key?("chunks") &&
           parsed.key?("aliases")
      raise ParseError, "Missing required keys in Claude response for #{asset.filename}"
    end

    chunks = parsed["chunks"]
    raise ParseError, "No chunks in response for #{asset.filename}" if chunks.blank?
  end

  def write_chunks_to_s3(prefix:, chunks:, asset:, canonical_name:, aliases:, ingestion_path:)
    original_uri = original_source_uri(asset)
    header       = identity_header(asset: asset, aliases: aliases, original_uri: original_uri)
    sidecar_json = sidecar_metadata(
      asset:          asset,
      canonical_name: canonical_name,
      aliases:        aliases,
      original_uri:   original_uri,
      ingestion_path: ingestion_path
    )

    chunks.each_with_index do |chunk, idx|
      txt_key = "#{prefix}/chunk_#{idx}.txt"
      @s3.upload_text(txt_key, header + chunk["text"].to_s)
      @s3.upload_text("#{txt_key}.metadata.json", sidecar_json)
    end
  end

  # Mirrors the legacy POST_CHUNKING Lambda contract so retrieval-side parsing
  # (bedrock/generation.txt STEP A/B + RULE 8, EntityExtractorService) is identical
  # for chunks produced by the batch path and chunks produced by the Bedrock-FM
  # parser path.
  def identity_header(asset:, aliases:, original_uri:)
    alias_line = Array(aliases).map { |a| a.to_s.strip }.reject(&:empty?).join(", ")

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
  def sidecar_metadata(asset:, canonical_name:, aliases:, original_uri:, ingestion_path:)
    JSON.generate(
      "metadataAttributes" => {
        "original_source_uri" => original_uri,
        "original_filename"   => asset.filename,
        "canonical_name"      => canonical_name.to_s,
        "doc_sha256"          => asset.sha256.to_s,
        "ingestion_path"      => ingestion_path,
        "aliases"             => Array(aliases).map(&:to_s)
      }
    )
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
