# frozen_string_literal: true

require "test_helper"

class QueryOrchestratorServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @orig_job = UploadAndSyncAttachmentsJob.method(:perform_later)
    UploadAndSyncAttachmentsJob.define_singleton_method(:perform_later) { |**| nil }
  end

  teardown do
    UploadAndSyncAttachmentsJob.define_singleton_method(:perform_later, @orig_job)
  end

  test "image + non-blank query returns images_uploaded without calling BedrockRagService" do
    rag_called = false
    orig_rag = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) { |*| rag_called = true; {} }

    image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "photo.jpg" }

    result = QueryOrchestratorService.new(
      "What is this?",
      images: [ image ]
    ).execute

    assert result.key?(:images_uploaded),     "must return images_uploaded key"
    assert_includes result[:images_uploaded], "photo.jpg"
    assert_not rag_called,                         "BedrockRagService must not be called when images are present"
  ensure
    BedrockRagService.define_method(:query, orig_rag)
  end

  test "image with blank query returns images_uploaded" do
    image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "scan.jpg" }

    result = QueryOrchestratorService.new(
      "",
      images: [ image ]
    ).execute

    assert result.key?(:images_uploaded)
    assert_includes result[:images_uploaded], "scan.jpg"
  end

  test "documents with blank query returns documents_uploaded without RAG" do
    rag_called = false
    orig_rag = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) { |*| rag_called = true; {} }

    doc = { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: "manual.pdf" }

    result = QueryOrchestratorService.new(
      "",
      documents: [ doc ]
    ).execute

    assert result.key?(:documents_uploaded)
    assert_not rag_called
  ensure
    BedrockRagService.define_method(:query, orig_rag)
  end

  test "document with non-blank query returns RAG answer and upload status metadata" do
    rag_called = false
    orig_rag = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) do |query, **|
      rag_called = true
      {
        answer: "Answer from already indexed documents for #{query}",
        citations: [],
        session_id: "session-existing"
      }
    end

    doc = { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: "new_manual.pdf" }

    result = QueryOrchestratorService.new(
      "What does the indexed manual say?",
      documents: [ doc ]
    ).execute

    assert rag_called, "RAG must still answer using already-indexed documents"
    assert_equal "Answer from already indexed documents for What does the indexed manual say?", result[:answer]
    assert_equal "session-existing", result[:session_id]
    assert_equal [ "new_manual.pdf" ], result[:documents_uploaded]
  ensure
    BedrockRagService.define_method(:query, orig_rag)
  end

  test "document upload job receives original query for urgent long-manual triage" do
    captured = nil
    UploadAndSyncAttachmentsJob.define_singleton_method(:perform_later) do |**kwargs|
      captured = kwargs
    end

    orig_rag = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) do |query, **|
      { answer: "answer #{query}", citations: [], session_id: nil }
    end

    doc = { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: "new_manual.pdf" }

    QueryOrchestratorService.new(
      "Necesito rescate de emergencia",
      documents: [ doc ]
    ).execute

    assert_equal "Necesito rescate de emergencia", captured[:query]
  ensure
    BedrockRagService.define_method(:query, orig_rag) if orig_rag
  end

  test "entity_sources separates media type from user pin provenance" do
    session = Struct.new(:active_entities).new({
      "Photo" => { "source" => "user_pin", "entity_type" => "image_upload" },
      "Manual" => { "source" => "user_pin", "entity_type" => "document" }
    })
    service = QueryOrchestratorService.new("Question", conv_session: session)

    assert_equal [ "image_upload", "document" ], service.send(:entity_sources)
  end

  test "entity_sources keeps legacy image uploads and defaults other legacy pins to documents" do
    session = Struct.new(:active_entities).new({
      "Photo" => { "source" => "image_upload" },
      "Manual" => { "source" => "user_pin" }
    })
    service = QueryOrchestratorService.new("Question", conv_session: session)

    assert_equal [ "image_upload", "document" ], service.send(:entity_sources)
  end

  test "entity_sources aligns with the narrowed URI subset" do
    session = Struct.new(:active_entities).new({
      "Photo" => {
        "source_uri" => "s3://bucket/photo.jpg",
        "entity_type" => "image_upload"
      },
      "Manual" => {
        "source_uri" => "s3://bucket/manual.pdf",
        "entity_type" => "document"
      }
    })
    service = QueryOrchestratorService.new(
      "Question",
      conv_session: session,
      entity_s3_uris: [ "s3://bucket/manual.pdf" ]
    )

    assert_equal [ "document" ], service.send(:entity_sources)
  end
end
