# frozen_string_literal: true

# Maps a BedrockQuery row (or equivalent hash) to a billing channel symbol.
#
# Channels:
#   :bedrock_rag              — end-user RAG queries via Bedrock invoke (source=query)
#   :anthropic_haiku_direct   — ingestion_parse, haiku, -direct (PageRelevanceFilter / Haiku gate)
#   :anthropic_sonnet_direct  — ingestion_parse, sonnet, -direct (ClaudeChunkingClient sync)
#   :anthropic_opus_direct    — ingestion_parse, opus, -direct
#   :anthropic_sonnet_batch   — ingestion_parse, sonnet, -batch (ManualBatchIngestion)
#   :anthropic_opus_batch     — ingestion_parse, opus, -batch
#   :bedrock_embed            — ingestion_embed (Nova embeddings)
#   :bedrock_legacy_parse     — ingestion_parse via TrackIngestionUsageJob estimates (no -direct/-batch)
#   :unknown                  — anything that doesn't match (log and skip)
class LlmUsageChannel
  BEDROCK_PROFILE_PREFIXES = %w[global. us. eu. anthropic.].freeze

  def self.for(model_id:, source:)
    new(model_id: model_id.to_s, source: source.to_s).channel
  end

  def initialize(model_id:, source:)
    @model_id = model_id
    @source   = source
  end

  def channel
    case @source
    when "query"
      :bedrock_rag
    when "ingestion_embed"
      :bedrock_embed
    when "ingestion_parse"
      classify_parse
    else
      :unknown
    end
  end

  private

  def classify_parse
    m = @model_id.downcase

    if m.end_with?("-direct")
      if m.include?("haiku")   then :anthropic_haiku_direct
      elsif m.include?("sonnet") then :anthropic_sonnet_direct
      elsif m.include?("opus")   then :anthropic_opus_direct
      else :unknown
      end
    elsif m.end_with?("-batch")
      if m.include?("sonnet") then :anthropic_sonnet_batch
      elsif m.include?("opus")  then :anthropic_opus_batch
      else :unknown
      end
    else
      :bedrock_legacy_parse
    end
  end
end
