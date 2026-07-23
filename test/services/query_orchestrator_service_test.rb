# frozen_string_literal: true

require "test_helper"

class QueryOrchestratorServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  parallelize(workers: 1)

  setup do
    clear_enqueued_jobs
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @upload_calls = []
    upload_calls = @upload_calls
    @orig_job = UploadAndSyncAttachmentsJob.method(:perform_later)
    UploadAndSyncAttachmentsJob.define_singleton_method(:perform_later) { |**kwargs| upload_calls << kwargs }
  end

  teardown do
    UploadAndSyncAttachmentsJob.define_singleton_method(:perform_later, @orig_job)
    Rails.cache = @previous_cache
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
    assert_empty @upload_calls
    photo_job = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }
    assert photo_job, "FieldPhotoAnalysisJob must be enqueued"
    args = photo_job[:args].first
    assert_equal "photo.jpg", args["filename"]
    assert args["image_token"].present?
    assert_match(/\Aphoto:/, result[:correlation_id])
    assert_equal result[:correlation_id], args["correlation_id"]
    assert_not_includes args.to_json, Base64.strict_encode64("xx")
    assert_nil args["image_payload"]
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

  test "same normalized image in the same account enqueues a cache-hit job without a temporary payload" do
    image = { data: Base64.strict_encode64("xx"), binary: "xx", media_type: "image/jpeg", filename: "scan.jpg" }
    sha = Digest::SHA256.hexdigest("xx")
    FieldPhotoDiagnosisCache.write(
      account_id: accounts(:legacy).id,
      sha256: sha,
      locale: "es",
      value: diagnosis_cache_value
    )

    result = QueryOrchestratorService.new(
      "What is this?",
      images: [ image ],
      account: accounts(:legacy),
      response_locale: :es,
      user_id: users(:one).id
    ).execute

    args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
    assert_nil args["image_token"]
    assert_equal sha, args["image_sha256"]
    assert_equal result[:correlation_id], args["correlation_id"]
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
    assert_equal 1, @upload_calls.size
    assert_empty enqueued_jobs.select { |job| job[:job] == FieldPhotoAnalysisJob }
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
      documents: [ doc ],
      account:   accounts(:legacy)
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
      documents: [ doc ],
      account:   accounts(:legacy)
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


  def diagnosis_cache_value
    {
      analysis: "analysis",
      compact_context: "context",
      canonical_name: "Panel",
      aliases: [],
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "UNKNOWN",
      visible_codes: [],
      model_id: "claude-sonnet-4-6-direct",
      input_tokens: 10,
      output_tokens: 5,
      original_cost: 0.000105,
      latency_ms: 100,
      created_at: Time.current.iso8601,
      contract_version: FieldPhotoPrompt::CONTRACT_VERSION
    }
  end
end
