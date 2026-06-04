# frozen_string_literal: true

# Maps a BedrockQuery row (or equivalent hash) to a billing channel symbol.
#
# Channels:
#   :bedrock_rag              — end-user RAG queries via Bedrock invoke (source=query)
#   :anthropic_haiku_direct   — ingestion_parse, haiku, -direct
#   :anthropic_sonnet_direct  — ingestion_parse, sonnet, -direct
#   :anthropic_opus_direct    — ingestion_parse, opus, -direct
#   :anthropic_sonnet_batch   — ingestion_parse, cost_v2 bulk/web (bulk_batch:/bulk_parse: + -batch + sonnet)
#   :anthropic_opus_batch     — ingestion_parse, cost_v2 bulk/web (bulk_* + -batch + opus)
#   :bulk_batch_v1_opus       — ingestion_parse, legacy bulk ZIP (batch_parse:, pre cost_v2); rollup only, not in home UI
#   :bedrock_embed            — ingestion_embed (Titan text embeddings)
#   :bedrock_legacy_parse     — ingestion_parse [parse] estimates (dormant FM path); rollup only, not in home UI
#   :unknown                  — anything that doesn't match (log and skip)
class LlmUsageChannel
  BEDROCK_PROFILE_PREFIXES = %w[global. us. eu. anthropic.].freeze

  def self.for(model_id:, source:, user_query: nil)
    new(model_id: model_id.to_s, source: source.to_s, user_query: user_query.to_s).channel
  end

  def initialize(model_id:, source:, user_query: "")
    @model_id    = model_id
    @source      = source
    @user_query  = user_query
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
    q = @user_query
    m = @model_id.downcase

    # Bedrock FM legacy estimates after BedrockIngestionJob on OWRPGSX6XK-style DS.
    return :bedrock_legacy_parse if q.start_with?("[parse]")

    # Legacy bulk ZIP: Anthropic Batch API whole-file Opus (batch_v1), NOT cost_v2, NOT Bedrock FM.
    return :bulk_batch_v1_opus if q.start_with?("batch_parse:")

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
    elsif bedrock_profile_model?(m)
      :bedrock_legacy_parse
    else
      :unknown
    end
  end

  def bedrock_profile_model?(normalized_model_id)
    BEDROCK_PROFILE_PREFIXES.any? { |pfx| normalized_model_id.start_with?(pfx) }
  end
end
