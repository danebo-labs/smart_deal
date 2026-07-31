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

  test "cached diagnosis with an existing durable photo enqueues without a temporary payload" do
    image = { data: Base64.strict_encode64("xx"), binary: "xx", media_type: "image/jpeg", filename: "scan.jpg" }
    sha = Digest::SHA256.hexdigest("xx")
    FieldPhotoDiagnosisCache.write(
      account_id: accounts(:legacy).id,
      sha256: sha,
      locale: "es",
      value: diagnosis_cache_value
    )
    existing_photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: sha, s3_key_original: "field_photos/#{accounts(:legacy).id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 2
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
    assert_equal existing_photo.id, args["field_photo_id"]
    assert_equal result[:correlation_id], args["correlation_id"]
  end

  test "cached diagnosis without a durable photo still writes the pending store so it can be persisted" do
    image = {
      data: Base64.strict_encode64("xx"), binary: "xx", media_type: "image/jpeg", filename: "scan.jpg",
      thumbnail_binary: "thumb-bytes", thumbnail_content_type: "image/jpeg",
      thumbnail_width: 88, thumbnail_height: 66
    }
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
    assert args["image_token"].present?
    assert_nil args["field_photo_id"]
    assert_equal sha, args["image_sha256"]
    assert_equal result[:correlation_id], args["correlation_id"]

    pending = FieldPhotoPendingImageStore.take(token: args["image_token"], account_id: accounts(:legacy).id)
    assert_equal "thumb-bytes", pending[:thumbnail_binary]
    assert_equal 88, pending[:thumbnail_width]
  end

  test "field_photo_id from another account is ignored and does not enqueue the job" do
    other_account_photo = FieldPhoto.create!(
      account_id: accounts(:climb).id, sha256: "f" * 64,
      s3_key_original: "field_photos/#{accounts(:climb).id}/#{'f' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    rag_called = false
    orig_rag = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) { |*| rag_called = true; { answer: "ok", citations: [], session_id: nil } }

    result = QueryOrchestratorService.new(
      "What does this mean?",
      account: accounts(:legacy),
      field_photo_id: other_account_photo.id
    ).execute

    assert rag_called, "must fall through to the normal text flow, not leak the resource"
    assert_equal "ok", result[:answer]
    assert_empty enqueued_jobs.select { |job| job[:job] == FieldPhotoAnalysisJob }
  ensure
    BedrockRagService.define_method(:query, orig_rag)
  end

  test "a valid field_photo_id enqueues the job with image_token: nil and the correct sha256, touching no binary" do
    photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: "g" * 64,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{'g' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )

    result = QueryOrchestratorService.new(
      "What does this mean?",
      account: accounts(:legacy),
      field_photo_id: photo.id,
      user_id: users(:one).id
    ).execute

    assert_equal [ "original.jpg" ], result[:images_uploaded]
    args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
    assert_nil args["image_token"]
    assert_equal photo.sha256, args["image_sha256"]
    assert_equal photo.id, args["field_photo_id"]
    assert_equal result[:correlation_id], args["correlation_id"]
  end

  test "field_photo_id is ignored when images are already attached" do
    photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: "h" * 64,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{'h' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "photo.jpg" }

    QueryOrchestratorService.new(
      "What is this?",
      images: [ image ],
      account: accounts(:legacy),
      field_photo_id: photo.id
    ).execute

    args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
    assert_not_equal photo.sha256, args["image_sha256"]
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

  test "deterministic_document_overview wins over model disambiguation when both would apply" do
    account = accounts(:legacy)
    doc = KbDocument.create!(account: account, s3_key: "uploads/#{SecureRandom.hex(4)}.pdf",
                              display_name: "SEGURIDADES 1.1-1", aliases: [])
    Rag::DocumentOverviewCache.write(
      account_id: account.id, kb_document_id: doc.id,
      value: { sections: [ { label: "S1", first_page: 1, last_page: 2, chunk_count: 1 } ],
               chunk_count: 1, source: "manifest" }
    )
    session = Struct.new(:active_entities).new({
      "SEGURIDADES 1.1-1" => { "canonical_name" => "SEGURIDADES 1.1-1", "kb_document_id" => doc.id,
                                "aliases" => [], "source" => "user_pin", "added_at" => Time.current.iso8601 }
    })
    # "SEGURIDADES" alone matches AmbiguousModelResponder's generic-hardware pattern
    # (and would proceed, since it does not also match an explicit equipment code
    # separated only by a space) — confirming the overview branch runs first.
    assert Rag::DeterministicIntent.ambiguous_hardware_query?("SEGURIDADES 1.1-1")

    result = QueryOrchestratorService.new(
      "SEGURIDADES 1.1-1",
      account: account,
      conv_session: session
    ).execute

    assert_equal "deterministic_document_overview", result[:generation_mode]
  end

  test "structured evidence route runs after document overview and before other retrieval responders" do
    route = Object.new
    route.define_singleton_method(:execute) do
      result = {
        answer: "Structured answer [1]",
        citations: [ { number: 1, title: "Manual" } ],
        session_id: nil,
        generation_mode: Rag::StructuredEvidenceRoute::GENERATION_MODE
      }
      Rag::StructuredEvidenceRoute::Outcome.new(status: :answered, result: result)
    end
    original_structured_build = Rag::StructuredEvidenceRoute.method(:build)
    original_ambiguous_build = Rag::AmbiguousModelResponder.method(:build)
    Rag::StructuredEvidenceRoute.define_singleton_method(:build) { |**| route }
    Rag::AmbiguousModelResponder.define_singleton_method(:build) do |**|
      raise "ambiguous responder must not run after the structured route succeeds"
    end

    result = QueryOrchestratorService.new(
      "¿Qué indica el BORNE X1?",
      account: accounts(:legacy),
      output_channel: :web
    ).execute

    assert_equal "Structured answer [1]", result[:answer]
    assert_equal Rag::StructuredEvidenceRoute::GENERATION_MODE, result[:generation_mode]
  ensure
    if original_structured_build
      Rag::StructuredEvidenceRoute.define_singleton_method(:build) { |**kwargs| original_structured_build.call(**kwargs) }
    end
    if original_ambiguous_build
      Rag::AmbiguousModelResponder.define_singleton_method(:build) { |**kwargs| original_ambiguous_build.call(**kwargs) }
    end
  end

  test "a structured abstention is terminal before ambiguous and deterministic responders" do
    route = Object.new
    route.define_singleton_method(:execute) do
      result = {
        answer: I18n.t("rag.data_not_available", locale: :es),
        citations: [],
        session_id: nil,
        generation_mode: Rag::StructuredEvidenceRoute::GENERATION_MODE
      }
      Rag::StructuredEvidenceRoute::Outcome.new(status: :abstained, result: result)
    end
    original_structured_build = Rag::StructuredEvidenceRoute.method(:build)
    original_ambiguous_build = Rag::AmbiguousModelResponder.method(:build)
    original_deterministic_build = Rag::DeterministicRenderer.method(:build)
    Rag::StructuredEvidenceRoute.define_singleton_method(:build) { |**| route }
    Rag::AmbiguousModelResponder.define_singleton_method(:build) do |**|
      raise "ambiguous responder must not run after structured abstention"
    end
    Rag::DeterministicRenderer.define_singleton_method(:build) do |**|
      raise "deterministic renderer must not run after structured abstention"
    end

    result = QueryOrchestratorService.new(
      "¿Qué indica el BORNE X1?",
      account: accounts(:legacy),
      output_channel: :web
    ).execute

    assert_equal I18n.t("rag.data_not_available", locale: :es), result[:answer]
    assert_empty result[:citations]
  ensure
    if original_structured_build
      Rag::StructuredEvidenceRoute.define_singleton_method(:build) { |**kwargs| original_structured_build.call(**kwargs) }
    end
    if original_ambiguous_build
      Rag::AmbiguousModelResponder.define_singleton_method(:build) { |**kwargs| original_ambiguous_build.call(**kwargs) }
    end
    if original_deterministic_build
      Rag::DeterministicRenderer.define_singleton_method(:build) { |**kwargs| original_deterministic_build.call(**kwargs) }
    end
  end

  test "an unavailable structured route falls through to one existing generative call" do
    route = Object.new
    route.define_singleton_method(:execute) do
      Rag::StructuredEvidenceRoute::Outcome.new(status: :unavailable, result: nil)
    end
    rag_service = Object.new
    calls = []
    rag_service.define_singleton_method(:query) do |question, **kwargs|
      calls << { question: question, kwargs: kwargs }
      { answer: "Fallback answer", citations: [], session_id: "fallback-session" }
    end
    original_structured_build = Rag::StructuredEvidenceRoute.method(:build)
    original_new = BedrockRagService.method(:new)
    Rag::StructuredEvidenceRoute.define_singleton_method(:build) { |**| route }
    BedrockRagService.define_singleton_method(:new) { |**| rag_service }

    result = QueryOrchestratorService.new(
      "¿Qué indica el BORNE X1?",
      account: accounts(:legacy),
      output_channel: :web
    ).execute

    assert_equal "Fallback answer", result[:answer]
    assert_equal 1, calls.size
  ensure
    if original_structured_build
      Rag::StructuredEvidenceRoute.define_singleton_method(:build) { |**kwargs| original_structured_build.call(**kwargs) }
    end
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
  end

  test "flag off preserves the existing generative path" do
    original_flag = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
    rag_service = Object.new
    calls = []
    rag_service.define_singleton_method(:query) do |question, **kwargs|
      calls << { question: question, kwargs: kwargs }
      { answer: "Existing answer", citations: [], session_id: "existing-session" }
    end
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |**| rag_service }
    source_uri = "s3://bucket/manual.pdf"
    session = Struct.new(:active_entities).new({
      "Manual" => {
        "source_uri" => source_uri,
        "entity_type" => "document",
        "source" => "user_pin"
      }
    })
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "¿Qué indica el BORNE X1?"
    )
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
    assert_nil Rag::StructuredEvidenceRoute.build(
      question: "¿Qué indica el BORNE X1?",
      account: accounts(:legacy),
      entity_s3_uris: [ source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      output_channel: :web
    )

    result = QueryOrchestratorService.new(
      "¿Qué indica el BORNE X1?",
      account: accounts(:legacy),
      conv_session: session,
      entity_s3_uris: [ source_uri ],
      output_channel: :web,
      force_entity_filter: true
    ).execute

    assert_equal "Existing answer", result[:answer]
    assert_equal "existing-session", result[:session_id]
    assert_equal 1, calls.size
  ensure
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    if original_flag.nil?
      ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED")
    else
      ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = original_flag
    end
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
