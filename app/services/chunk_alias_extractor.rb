# frozen_string_literal: true

# Extracts the semantic document name and aliases from Bedrock KB chunks
# using the `retrieve` API (vector search only — no LLM call).
#
# Parses two well-structured fields that Opus always generates:
#   1. **Document:** <name>        → canonical_name
#   2. **DOCUMENT_ALIASES:**       → list of aliases
#
# Returns nil when the document cannot be found or parsed.
#
# @example
#   result = ChunkAliasExtractor.new(kb_id: "VBB72VKABV").call("wa_20260326_012702_0.jpeg")
#   # => { canonical_name: "Junction Box Car Top", aliases: ["junction, box, car top", "DRG 6061-05-014", ...] }
class ChunkAliasExtractor
  include AwsClientInitializer

  DOCUMENT_HEADER = /\*\*Document:\*\*\s*(.+?)(?:\s*\||\s*$)/m.freeze
  ALIASES_BLOCK   = /\*\*DOCUMENT_ALIASES:\*\*\s*((?:- .+\n?)+)/.freeze
  SOURCE_URI_KEY  = "x-amz-bedrock-kb-source-uri"

  def initialize(kb_id:)
    @client = Aws::BedrockAgentRuntime::Client.new(build_aws_client_options)
    @kb_id  = kb_id
  end

  # @param wa_filename [String] e.g. "wa_20260326_012702_0.jpeg"
  # @return [Hash, nil] { canonical_name:, aliases: }
  def call(wa_filename)
    s3_uri = build_s3_uri(wa_filename)
    Rails.logger.info("ChunkAliasExtractor: querying KB #{@kb_id} for #{s3_uri}")

    chunk = fetch_s0_chunk(s3_uri, wa_filename)
    unless chunk
      Rails.logger.warn("ChunkAliasExtractor: no chunks returned for #{wa_filename}")
      return nil
    end

    content = chunk.content&.text.to_s
    Rails.logger.info("ChunkAliasExtractor: chunk content length=#{content.length} first_200=#{content.first(200).inspect}")

    canonical = parse_canonical(content)
    aliases   = parse_aliases(content)

    if canonical.blank?
      Rails.logger.warn("ChunkAliasExtractor: could not parse canonical name from chunk for #{wa_filename}")
      return nil
    end

    Rails.logger.info("ChunkAliasExtractor: #{wa_filename} → canonical=#{canonical.inspect} aliases=#{aliases.inspect}")
    { canonical_name: canonical, aliases: aliases }
  rescue StandardError => e
    Rails.logger.error("ChunkAliasExtractor: failed for #{wa_filename} — #{e.class}: #{e.message}")
    nil
  end

  private

  def build_s3_uri(wa_filename)
    m      = wa_filename.match(/\Awa_(\d{4})(\d{2})(\d{2})_/)
    date   = m ? "#{m[1]}-#{m[2]}-#{m[3]}" : Date.current.iso8601
    bucket = ENV.fetch('KNOWLEDGE_BASE_S3_BUCKET', 'multimodal-source-destination')
    "s3://#{bucket}/uploads/#{date}/#{wa_filename}"
  end

  def fetch_s0_chunk(s3_uri, wa_filename)
    resp = @client.retrieve(
      knowledge_base_id: @kb_id,
      retrieval_query:   { text: "DOCUMENT_ALIASES document identification" },
      retrieval_configuration: {
        vector_search_configuration: {
          number_of_results: 5,
          filter: { equals: { key: SOURCE_URI_KEY, value: s3_uri } }
        }
      }
    )

    results = resp.retrieval_results || []
    results.find { |r| r.content&.text.to_s.include?("DOCUMENT_ALIASES") } || results.first
  rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
    Rails.logger.warn("ChunkAliasExtractor: retrieve failed — #{e.message}")
    nil
  end

  def parse_canonical(content)
    match = content.match(DOCUMENT_HEADER)
    return nil unless match

    canon = match[1].strip.sub(/\.pdf\z/i, '')
    return nil if canon.include?("[") || canon.match?(/unavailable/i)

    canon
  end

  def parse_aliases(content)
    match = content.match(ALIASES_BLOCK)
    return [] unless match

    raw   = match[1].strip
    lines = raw.split(/\n/).map(&:strip).compact_blank

    if lines.size == 1
      line = lines.first
      line.sub(/\A-\s+/, "").split(" - ").map(&:strip).compact_blank
    else
      raw.scan(/^-\s+(.+)$/).flatten.map(&:strip).compact_blank
    end
  end
end
