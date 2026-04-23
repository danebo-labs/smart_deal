# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/kb_documents_rake_helper.rb")

class KbDocumentsRakeHelperTest < ActiveSupport::TestCase
  FakePage = Struct.new(:document_details, :next_token, keyword_init: true)

  class FakeBedrockAgentDocsClient
    def initialize(pages)
      @pages = pages
      @idx = 0
    end

    def list_knowledge_base_documents(knowledge_base_id:, data_source_id:, max_results:, next_token:)
      page = @pages[@idx]
      @idx += 1
      FakePage.new(document_details: page.fetch(:details), next_token: page[:next_token])
    end
  end

  test "collect_document_details concatenates paginated responses" do
    d1 = Struct.new(:status, :identifier, :updated_at, :status_reason).new("INDEXED", nil, nil, nil)
    d2 = Struct.new(:status, :identifier, :updated_at, :status_reason).new("FAILED", nil, nil, "x")
    client = FakeBedrockAgentDocsClient.new([
      { details: [ d1 ], next_token: "t1" },
      { details: [ d2 ], next_token: nil }
    ])
    out = KbDocumentsRakeHelper.collect_document_details(client, "KB1", "DS1")
    assert_equal 2, out.size
    assert_equal "INDEXED", out[0].status
    assert_equal "FAILED", out[1].status
  end

  test "detail_as_hash includes s3 uri when present" do
    id = Struct.new(:s3, :custom, :data_source_type).new(
      Struct.new(:uri).new("s3://b/k.pdf"),
      nil,
      "S3"
    )
    d = Struct.new(:status, :identifier, :updated_at, :status_reason).new(
      "INDEXED", id, Time.utc(2026, 4, 1, 12, 0, 0), nil
    )
    h = KbDocumentsRakeHelper.detail_as_hash(d)
    assert_equal "INDEXED", h[:status]
    assert_equal "s3://b/k.pdf", h[:uri]
    assert_includes h[:updated_at].to_s, "2026"
  end

  test "s3_uri_from_detail reads nested identifier" do
    id = Struct.new(:s3, :custom, :data_source_type).new(Struct.new(:uri).new("s3://x/y"), nil, nil)
    d = Struct.new(:identifier).new(id)
    assert_equal "s3://x/y", KbDocumentsRakeHelper.s3_uri_from_detail(d)
  end
end
