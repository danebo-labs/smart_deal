# frozen_string_literal: true

require "test_helper"

class LiveAwsBlockTest < ActiveSupport::TestCase
  test "a real runtime converse is refused before any request" do
    client = Aws::BedrockRuntime::Client.new(stub_responses: true)

    error = assert_raises(LiveAwsBlock::Refused) do
      client.converse(model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0", messages: [])
    end

    assert_includes error.message, "Aws::BedrockRuntime::Client#converse"
  end

  test "a real retrieve is refused before any request" do
    client = Aws::BedrockAgentRuntime::Client.new(stub_responses: true)

    error = assert_raises(LiveAwsBlock::Refused) do
      client.retrieve(knowledge_base_id: "Y7RZWMFJSR", retrieval_query: { text: "puerta" })
    end

    assert_includes error.message, "Aws::BedrockAgentRuntime::Client#retrieve"
  end

  test "owner mode cannot reach Bedrock through the interpreter client" do
    previous = ENV.fetch("HAIKU_QUERY_ANALYSIS_MODE", nil)
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    Rag::HaikuQueryAnalysisFlag.reset_unknown_warning!

    assert_raises(LiveAwsBlock::Refused) do
      BedrockClient.new.converse(model_id: Rag::TurnInterpreter::MODEL_ID, messages: [], inference_config: {})
    end
  ensure
    if previous.nil?
      ENV.delete("HAIKU_QUERY_ANALYSIS_MODE")
    else
      ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous
    end
  end
end
