# frozen_string_literal: true

require "test_helper"

class BedrockEmbeddingModelTest < ActiveSupport::TestCase
  setup do
    @orig = ENV["BEDROCK_EMBEDDING_MODEL_ID"]
    ENV.delete("BEDROCK_EMBEDDING_MODEL_ID")
  end

  teardown do
    if @orig
      ENV["BEDROCK_EMBEDDING_MODEL_ID"] = @orig
    else
      ENV.delete("BEDROCK_EMBEDDING_MODEL_ID")
    end
  end

  test "default model id is Titan Text v2" do
    assert_equal "amazon.titan-embed-text-v2:0", BedrockEmbeddingModel.model_id
  end

  test "strips foundation-model ARN prefix" do
    ENV["BEDROCK_EMBEDDING_MODEL_ID"] =
      "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
    assert_equal "amazon.titan-embed-text-v2:0", BedrockEmbeddingModel.model_id
  end

  test "titan v2 cost uses AWS on-demand rate" do
    rec = BedrockQuery.new(
      model_id: "amazon.titan-embed-text-v2:0",
      input_tokens: 10_000,
      output_tokens: 0
    )
    assert_in_delta 0.0002, rec.cost, 0.000001
  end
end
