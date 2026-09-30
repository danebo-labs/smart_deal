# frozen_string_literal: true

require "test_helper"

class Rag::R1aRetrievalProbeTest < ActiveSupport::TestCase
  setup do
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "test-kb-id"
    @viewer = accounts(:legacy)
    @service = BedrockRagService.new(account: @viewer)
  end

  teardown do
    ENV.delete("BEDROCK_KNOWLEDGE_BASE_ID")
  end

  test "logged reason matches the publication gate" do
    sha36 = "121bfffe0827f6bc681ba9bdc91050390055"
    pilot_id = accounts(:pilot).id.to_s
    cases = {
      "owner bulk" => [ { "account_id" => @viewer.id.to_s, "document_id" => sha36 }, "owner", true ],
      "blank account" => [ { "document_id" => sha36 }, "account_id_blank", false ],
      "nil metadata" => [ nil, "metadata_unreadable", false ],
      "general without account" => [ { "manual_corpus" => "general" }, "account_id_blank", false ],
      "historical shared" => [ { "account_id" => pilot_id, "document_id" => sha36 }, "shared_member", true ],
      "new private shared" => [ { "account_id" => pilot_id, "manual_corpus" => "account" }, "private_corpus", false ],
      "foreign photo" => [ { "account_id" => pilot_id, "ingestion_path" => "field_photo_v1" }, "foreign_photo", false ],
      "own photo" => [ { "account_id" => @viewer.id.to_s, "ingestion_path" => "field_photo_v1" }, "owner", true ],
      "foreign private" => [ { "account_id" => accounts(:climb).id.to_s }, "foreign_private", false ]
    }

    cases.each do |name, (metadata, reason, kept)|
      chunk = { metadata: metadata }
      assert_equal kept, @service.send(:publishable_retrieved_chunk?, chunk), name
      assert_equal reason, Rag::R1aRetrievalProbe.reason_for(
        Rag::R1aRetrievalProbe.metadata_of(chunk),
        @viewer.id
      ), name
    end
  end

  test "a probe failure does not raise" do
    assert_nil Rag::R1aRetrievalProbe.emit(correlation_id: "query:1", stage: "bedrock_request_filter", query: "KONE", filter: { or_all: [] })
  end
end
