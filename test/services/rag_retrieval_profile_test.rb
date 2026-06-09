# frozen_string_literal: true

require "test_helper"

class RagRetrievalProfileTest < ActiveSupport::TestCase
  test "returns 8 when no entities pinned" do
    profile = RagRetrievalProfile.new(entity_sources: [])
    assert_equal 8, profile.number_of_results
  end

  test "returns 10 for photo-only session" do
    profile = RagRetrievalProfile.new(entity_sources: [ "image_upload", "image_upload" ])
    assert_equal 10, profile.number_of_results
  end

  test "returns 7 for document-only session" do
    profile = RagRetrievalProfile.new(entity_sources: [ "document", "document" ])
    assert_equal 7, profile.number_of_results
  end

  test "returns 7 for mixed photo+document session" do
    profile = RagRetrievalProfile.new(entity_sources: [ "image_upload", "document" ])
    assert_equal 7, profile.number_of_results
  end

  test "single photo pin returns 10" do
    assert_equal 10, RagRetrievalProfile.new(entity_sources: [ "image_upload" ]).number_of_results
  end

  test "single document pin returns 7" do
    assert_equal 7, RagRetrievalProfile.new(entity_sources: [ "document" ]).number_of_results
  end

  test "handles nil in entity_sources array" do
    profile = RagRetrievalProfile.new(entity_sources: [ nil, "document" ])
    assert_equal 7, profile.number_of_results
  end
end
