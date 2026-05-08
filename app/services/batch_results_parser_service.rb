# frozen_string_literal: true

# Parses a single Anthropic batch result for a BulkUploadAsset:
#   1. Extracts and validates the JSON from Claude's response.
#   2. Prepends the legacy identity header (DOCUMENT / SOURCE_URI / SEARCH_ALIASES)
#      to each chunk so retrieval (`bedrock/generation.txt`, EntityExtractorService,
#      ChunkAliasExtractor) sees the same shape the post-chunking Lambda produces
#      for the OWRPGSX6XK data source.
#   3. Writes each chunk as a .txt file PLUS a `<key>.metadata.json` sidecar to S3
#      under bulk_chunks/{date}/{sha256}/. The sidecar carries `customMetadata`
#      that maps each chunk back to the ORIGINAL asset URI — Bedrock's S3 connector
#      auto-attaches it to the chunk's customMetadata column, which is the seam
#      retrieval-side filtering will use to restore pin behavior for batch chunks
#      and to plug in tenant scoping later.
#   4. Persists canonical_name, aliases, chunks_count, chunks_s3_prefix on the asset.
#   5. Transitions the asset status to "parsed" (or "failed" on error).
class BatchResultsParserService
  class ParseError < StandardError; end

  CHUNK_PREFIX_TPL = "bulk_chunks/%s/%s"

  def initialize(s3_service: nil)
    @s3 = s3_service || S3DocumentsService.new
  end

  # @param asset  [BulkUploadAsset]
  # @param result [Object] Anthropic batch individual response (.custom_id, .result.type, .result.message)
  # @return [BulkUploadAsset] with status "parsed"
  # @raise [ParseError] propagated after marking asset failed
  def call(asset:, result:)
    unless result.result.type.to_s == "succeeded"
      raise ParseError, "Result type '#{result.result.type}' for #{asset.filename}"
    end

    text   = extract_text(result.result.message)
    parsed = parse_json(text)
    validate!(parsed, asset)

    date_prefix   = Date.current.iso8601
    chunks_prefix = format(CHUNK_PREFIX_TPL, date_prefix, asset.sha256)
    aliases       = Array(parsed["aliases"])

    write_chunks_to_s3(
      prefix:         chunks_prefix,
      chunks:         parsed["chunks"],
      asset:          asset,
      canonical_name: parsed["document_name"],
      aliases:        aliases
    )

    asset.update!(
      canonical_name:   parsed["document_name"],
      aliases:          aliases,
      chunks_count:     parsed["chunks"].length,
      chunks_s3_prefix: chunks_prefix,
      status:           "parsed"
    )
    asset.broadcast_replace!
    asset
  rescue ParseError => e
    asset.update_columns(status: "failed", error_message: e.message)
    asset.broadcast_replace!
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
    JSON.parse(text.strip)
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

    first_text = chunks.first["text"].to_s
    doc_name   = parsed["document_name"].to_s

    unless first_text.start_with?("**Document: #{doc_name}**")
      raise ParseError, "chunk[0].text missing **Document:** header for #{asset.filename}"
    end
    unless first_text.include?("**DOCUMENT_ALIASES:**")
      raise ParseError, "chunk[0].text missing **DOCUMENT_ALIASES:** header for #{asset.filename}"
    end
  end

  def write_chunks_to_s3(prefix:, chunks:, asset:, canonical_name:, aliases:)
    original_uri = original_source_uri(asset)
    header       = identity_header(asset: asset, aliases: aliases, original_uri: original_uri)
    sidecar_json = sidecar_metadata(
      asset:          asset,
      canonical_name: canonical_name,
      aliases:        aliases,
      original_uri:   original_uri
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
  # resulting chunk. Keys are intentionally non-reserved (Bedrock owns the
  # `x-amz-bedrock-kb-*` namespace). `original_source_uri` is the seam retrieval
  # filtering should OR alongside `x-amz-bedrock-kb-source-uri` to make pin-based
  # filters work for batch chunks. `account_id` / `project_id` are reserved here
  # as multi-tenant seams — left absent today (MVP is global pool).
  def sidecar_metadata(asset:, canonical_name:, aliases:, original_uri:)
    JSON.generate(
      "metadataAttributes" => {
        "original_source_uri" => original_uri,
        "original_filename"   => asset.filename,
        "canonical_name"      => canonical_name.to_s,
        "doc_sha256"          => asset.sha256.to_s,
        "ingestion_path"      => "batch_v1",
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
