# frozen_string_literal: true

require "test_helper"

class LlmUsageChannelTest < ActiveSupport::TestCase
  # Table-driven: [model_id, source, expected_channel]
  CASES = [
    # RAG Bedrock (query source)
    [ "us.anthropic.claude-haiku-4-5-20251001-v1:0", "query",            :bedrock_rag ],
    [ "global.anthropic.claude-sonnet-4-6-v1",       "query",            :bedrock_rag ],
    [ "anthropic.claude-haiku-3-5",                  "query",            :bedrock_rag ],

    # Anthropic direct (ingestion_parse + -direct)
    [ "claude-haiku-4-5-20251001-direct",             "ingestion_parse",  :anthropic_haiku_direct ],
    [ "claude-sonnet-4-6-direct",                     "ingestion_parse",  :anthropic_sonnet_direct ],
    [ "claude-opus-4-7-direct",                       "ingestion_parse",  :anthropic_opus_direct ],

    # Anthropic batch (ingestion_parse + -batch)
    [ "claude-sonnet-4-6-batch",                      "ingestion_parse",  :anthropic_sonnet_batch ],
    [ "claude-opus-4-7-batch",                        "ingestion_parse",  :anthropic_opus_batch ],

    # Bedrock legacy parse (ingestion_parse, no suffix)
    [ "global.anthropic.claude-opus-4-6-v1",          "ingestion_parse",  :bedrock_legacy_parse ],
    [ "anthropic.claude-3-sonnet",                    "ingestion_parse",  :bedrock_legacy_parse ],

    # Embed
    [ "amazon.titan-embed-text-v1",                   "ingestion_embed",  :bedrock_embed ],

    # Unknown source
    [ "some-model",                                   "other_source",     :unknown ]
  ].freeze

  CASES.each do |model_id, source, expected|
    test "#{source} / #{model_id} → #{expected}" do
      assert_equal expected, LlmUsageChannel.for(model_id: model_id, source: source)
    end
  end
end
