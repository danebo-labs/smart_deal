# frozen_string_literal: true

require "test_helper"

class BedrockKbChunkTest < ActiveSupport::TestCase
  test "vectors constants match Bedrock KB API field mapping (VBB72VKABV snapshot)" do
    assert_equal "VBB72VKABV", BedrockKbChunk::KNOWLEDGE_BASE_ID
    assert_equal "bedrock_integration", BedrockKbChunk::VECTOR_SCHEMA
    assert_equal "bedrock_knowledge_base", BedrockKbChunk::VECTOR_TABLE
    assert_equal "bedrock_integration.bedrock_knowledge_base", BedrockKbChunk::VECTOR_QUALIFIED_NAME
    assert_equal 1024, BedrockKbChunk::EMBEDDING_DIMENSION
    assert_equal "id", BedrockKbChunk::COLUMN_PRIMARY_KEY
    assert_equal "embedding", BedrockKbChunk::COLUMN_EMBEDDING
    assert_equal "chunks", BedrockKbChunk::COLUMN_TEXT
    assert_equal "metadata", BedrockKbChunk::COLUMN_METADATA
    assert_equal "custommetadata", BedrockKbChunk::COLUMN_CUSTOM_METADATA
  end

  test "model stays abstract (no default connection to vector store)" do
    assert BedrockKbChunk.abstract_class?
  end
end
