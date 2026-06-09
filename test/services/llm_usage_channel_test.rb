# frozen_string_literal: true

require "test_helper"

class LlmUsageChannelTest < ActiveSupport::TestCase
  # [model_id, source, user_query, expected_channel]
  CASES = [
    [ "us.anthropic.claude-haiku-4-5-20251001-v1:0",     "query",           nil,                     :bedrock_rag ],
    [ "global.anthropic.claude-haiku-4-5-20251001-v1:0", "query",           nil,                     :bedrock_rag ],
    [ "claude-sonnet-4-6-direct",                        "ingestion_parse", "web_parse: f.pdf",      :anthropic_sonnet_direct ],
    [ "claude-opus-4-7-batch",                           "ingestion_parse", "bulk_parse: photo.png", :anthropic_opus_batch ],
    [ "claude-opus-4-8-batch",                           "ingestion_parse", "bulk_parse: photo.png", :anthropic_opus_batch ],
    [ "claude-opus-4-8-direct",                          "ingestion_parse", "web_parse: photo.jpg",  :anthropic_opus_direct ],
    [ "claude-sonnet-4-6-batch",                         "ingestion_parse", "bulk_batch: f.pdf p1/1", :anthropic_sonnet_batch ],
    [ "claude-opus-4-7",                                 "ingestion_parse", "batch_parse: doc.pdf",  :bulk_batch_v1_opus ],
    [ "global.anthropic.claude-opus-4-6-v1",             "ingestion_parse", "[parse] doc.pdf",       :bedrock_legacy_parse ],
    [ "global.anthropic.claude-opus-4-6-v1",             "ingestion_parse", nil,                     :bedrock_legacy_parse ],
    [ "claude-opus-4-7",                                 "ingestion_parse", nil,                     :unknown ],
    [ "amazon.titan-embed-text-v1",                      "ingestion_embed", nil,                     :bedrock_embed ]
  ].freeze

  CASES.each do |model_id, source, user_query, expected|
    label = user_query || "(nil)"
    test "#{source} / #{model_id} / #{label} → #{expected}" do
      assert_equal expected, LlmUsageChannel.for(model_id: model_id, source: source, user_query: user_query)
    end
  end
end
