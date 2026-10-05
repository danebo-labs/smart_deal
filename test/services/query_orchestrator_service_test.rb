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
    assert_enqueued_with(job: WarmBedrockKbJob)
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
    assert_no_enqueued_jobs only: WarmBedrockKbJob
  end

  test "image with blank query returns the Spanish analyzing message and response_locale under an English ambient I18n.locale" do
    image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "scan.jpg" }

    # response_locale: :es simulates what RagQueryConcern#resolve_response_locale resolves to
    # for a blank question (P0 fix: BedrockRagService.detect_language_from_question no longer
    # falls back to the ambient/session I18n.locale for a blank question). I18n.locale is set
    # to :en here to prove the orchestrator's own I18n.with_locale wrap — not the ambient
    # session locale — decides the "analyzing…" message language (Causa B).
    result = I18n.with_locale(:en) do
      QueryOrchestratorService.new(
        "",
        images: [ image ],
        response_locale: :es
      ).execute
    end

    assert_equal I18n.t("rag.image_analyzing_message", locale: :es), result[:answer]
    assert_equal "es", result[:response_locale]
  end

  test "an uploaded image with a durable photo still writes a pending token and warms the KB" do
    image = { data: Base64.strict_encode64("xx"), binary: "xx", media_type: "image/jpeg", filename: "scan.jpg" }
    sha = Digest::SHA256.hexdigest("xx")
    existing_photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: sha, s3_key_original: "field_photos/#{accounts(:legacy).id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 2
    )
    events = capture_pilot_usage_events do
      QueryOrchestratorService.new(
        "What is this?",
        images: [ image ],
        account: accounts(:legacy),
        response_locale: :es,
        user_id: users(:one).id
      ).execute
    end

    args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
    assert args["image_token"].present?
    assert_equal sha, args["image_sha256"]
    assert_equal existing_photo.id, args["field_photo_id"]
    assert_enqueued_with(job: WarmBedrockKbJob)
    submitted = events.find { |event| event["event"] == "photo_submitted" }
    assert submitted
    assert_not submitted.key?("cache_status")
  end

  test "an uploaded image writes the pending token including the thumbnail" do
    image = {
      data: Base64.strict_encode64("xx"), binary: "xx", media_type: "image/jpeg", filename: "scan.jpg",
      thumbnail_binary: "thumb-bytes", thumbnail_content_type: "image/jpeg",
      thumbnail_width: 88, thumbnail_height: 66
    }
    sha = Digest::SHA256.hexdigest("xx")

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
    assert_enqueued_with(job: WarmBedrockKbJob)

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
    store_visual_observation!(photo)

    result = QueryOrchestratorService.new(
      "What does this mean?",
      account: accounts(:legacy),
      field_photo_id: photo.id,
      user_id: users(:one).id
    ).execute

    assert_equal [ "original.jpg" ], result[:images_uploaded]
    args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
    assert_nil args["image_token"]
    assert_equal "reuse", args["continuity"]
    assert_equal photo.sha256, args["image_sha256"]
    assert_equal photo.id, args["field_photo_id"]
    assert_equal result[:correlation_id], args["correlation_id"]
  end

  test "reusing a field_photo_id returns the Spanish analyzing message and response_locale under an English ambient I18n.locale" do
    photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: "i" * 64,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{'i' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    store_visual_observation!(photo)

    result = I18n.with_locale(:en) do
      QueryOrchestratorService.new(
        "What does this mean?",
        account: accounts(:legacy),
        field_photo_id: photo.id,
        response_locale: :es
      ).execute
    end

    assert_equal I18n.t("rag.image_analyzing_message", locale: :es), result[:answer]
    assert_equal "es", result[:response_locale]
  end

  test "same-turn photo question keeps the literal question until after vision" do
    session = ConversationSession.create!(
      identifier: "n0-same-turn",
      channel: "web",
      account: accounts(:legacy),
      user: users(:one),
      expires_at: 1.day.from_now
    )
    question = "¿Qué ves y qué debería revisar primero?"
    interpreter_calls = 0
    original = Rag::TurnInterpreter.method(:call)
    Rag::TurnInterpreter.define_singleton_method(:call) do |**kwargs|
      interpreter_calls += 1
      original.call(**kwargs)
    end

    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      session.ensure_case_for_photo_submission!(correlation_id: "query:goal")
      episode = Rag::ActiveEpisode.parse(session.reload.active_episode)
      episode.assign_goal!("no nivela en planta 3", correlation_id: "query:goal")
      session.update!(active_episode: episode.to_h)
      image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "placa.jpg" }

      QueryOrchestratorService.new(
        question,
        images: [ image ],
        account: accounts(:legacy),
        conv_session: session,
        user_id: users(:one).id,
        correlation_id: "photo:n0-same-turn"
      ).execute
    end

    args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
    assert_equal question, args["question"]
    assert_not_includes args["question"], "no nivela en planta 3"
    assert_equal 0, interpreter_calls
  ensure
    Rag::TurnInterpreter.define_singleton_method(:call) { |**kwargs| original.call(**kwargs) } if original
  end

  test "fresh image upload enqueues the job with the literal question" do
    image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "photo.jpg" }

    QueryOrchestratorService.new(
      "Que está mostrando la pantalla?",
      images: [ image ],
      account: accounts(:legacy)
    ).execute

    args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
    assert_equal "Que está mostrando la pantalla?", args["question"]
  end

  test "field_photo_id reuse enqueues the job with the literal question" do
    photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: "j" * 64,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{'j' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    store_visual_observation!(photo)

    QueryOrchestratorService.new(
      "Que está mostrando la pantalla?",
      account: accounts(:legacy),
      field_photo_id: photo.id
    ).execute

    args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
    assert_equal "reuse", args["continuity"]
    assert_equal "Que está mostrando la pantalla?", args["question"]
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
    session = Object.new
    session.define_singleton_method(:uses_document_focus?) { true }
    session.define_singleton_method(:document_focus_entries) do
      [ {
        "kb_document_id" => doc.id,
        "display_name" => "SEGURIDADES 1.1-1",
        "source_uri" => doc.canonical_uri,
        "added_at" => Time.current.iso8601
      } ]
    end
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

  test "an elliptical raw turn reaches structured rescue without the composed history" do
    composed = "EM2000 DL4 CTA ALJO\nEDEL K2 cerrojos exteriores\nEdel-k2"
    raw = "Edel-k2"
    episode = {
      "goal" => { "text" => "EDEL K2 cerrojos exteriores" },
      "identifiers" => [
        { "value" => "EM2000", "source" => "user" },
        { "value" => "DL4", "source" => "user" }
      ]
    }
    source_uri = "s3://bucket/edel-k2.pdf"
    KbDocument.create!(account: accounts(:legacy), s3_key: source_uri, display_name: "EDEL K2", aliases: [])
    session = Struct.new(:active_episode, :active_entities, :id).new(
      episode,
      { "edel" => { "source_uri" => source_uri, "entity_type" => "document" } },
      42
    )
    captured = nil
    built = nil
    original_structured_build = Rag::StructuredEvidenceRoute.method(:build)
    original_flag = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    Rag::StructuredEvidenceRoute.define_singleton_method(:build) do |**kwargs|
      captured = kwargs
      route = original_structured_build.call(**kwargs)
      built = route
      if route
        route.define_singleton_method(:execute) do
          Rag::StructuredEvidenceRoute::Outcome.new(status: :unavailable, result: nil)
        end
      end
      route
    end
    rag_service = Object.new
    rag_service.define_singleton_method(:query) { |*| { answer: "ok", citations: [], session_id: "s" } }
    rag_service.define_singleton_method(:retrieve_chunks) { |*| { chunks: [], retrieval_trace: {} } }
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |**| rag_service }

    QueryOrchestratorService.new(
      composed,
      raw_question: raw,
      account: accounts(:legacy),
      conv_session: session,
      entity_s3_uris: [ source_uri ],
      output_channel: :web,
      response_locale: :es
    ).execute

    assert_equal composed, captured[:question]
    assert_equal raw, captured[:raw_question]
    assert built, "the composed pin question must still open the structured route"
    rescue_text = built.send(:rescue_base_text)
    assert_includes rescue_text, "cerrojos exteriores"
    assert_includes rescue_text, raw
    %w[EM2000 DL4 CTA ALJO].each { |token| assert_not_includes rescue_text, token }
  ensure
    if original_structured_build
      Rag::StructuredEvidenceRoute.define_singleton_method(:build) { |**kwargs| original_structured_build.call(**kwargs) }
    end
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    original_flag.nil? ? ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED") : ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = original_flag
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
    KbDocument.create!(account: accounts(:legacy), s3_key: source_uri, display_name: "Manual", aliases: [])
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

  test "a mixed unauthorized focus denies retrieval and does not call Bedrock" do
    own = KbDocument.create!(
      account: accounts(:legacy), s3_key: "manuals/own-f5.pdf", display_name: "Own", aliases: []
    )
    foreign = KbDocument.create!(
      account: accounts(:climb), s3_key: "manuals/foreign-f5.pdf", display_name: "Foreign", aliases: []
    )
    calls = 0
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) do |**kwargs|
      calls += 1
      original_new.call(**kwargs)
    end

    result = QueryOrchestratorService.new(
      "¿Qué reviso si no nivela?",
      account: accounts(:legacy),
      entity_s3_uris: [ own.canonical_uri, foreign.canonical_uri ],
      force_entity_filter: true
    ).execute

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal false, result[:model_invoked]
    assert_equal 0, result.dig(:retrieval_trace, :bedrock_calls)
    assert_equal 0, calls
  ensure
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
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

  # ============================================
  # Tests for auto_scope_filter wiring (auto-scope-retrieval plan)
  # ============================================

  test "auto_scope_filter is passed to BedrockRagService#query" do
    original_flag = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
    rag_service = Object.new
    calls = []
    rag_service.define_singleton_method(:query) do |question, **kwargs|
      calls << { question: question, kwargs: kwargs }
      { answer: "ok", citations: [], session_id: "s" }
    end
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |**| rag_service }

    KbDocument.create!(account: accounts(:legacy), s3_key: "s3://bucket/soprel.pdf", display_name: "SOPREL", aliases: [])
    QueryOrchestratorService.new(
      "que es el Esquema SOPREL?",
      account: accounts(:legacy),
      entity_s3_uris: [ "s3://bucket/soprel.pdf" ],
      auto_scope_filter: true
    ).execute

    assert_equal 1, calls.size
    assert_equal true, calls.first[:kwargs][:auto_scope_filter]
  ensure
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    original_flag.nil? ? ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED") : ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = original_flag
  end

  test "auto_scope_filter defaults to false when the caller omits it" do
    original_flag = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
    rag_service = Object.new
    calls = []
    rag_service.define_singleton_method(:query) do |question, **kwargs|
      calls << { question: question, kwargs: kwargs }
      { answer: "ok", citations: [], session_id: "s" }
    end
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |**| rag_service }

    QueryOrchestratorService.new("hello", account: accounts(:legacy)).execute

    assert_equal false, calls.first[:kwargs][:auto_scope_filter]
  ensure
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    original_flag.nil? ? ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED") : ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = original_flag
  end

  test "auto_scope_filter is not forwarded to the deterministic route builders" do
    captured_kwargs = []
    original_structured_build = Rag::StructuredEvidenceRoute.method(:build)
    original_ambiguous_build = Rag::AmbiguousModelResponder.method(:build)
    original_deterministic_build = Rag::DeterministicRenderer.method(:build)
    Rag::StructuredEvidenceRoute.define_singleton_method(:build) do |**kwargs|
      captured_kwargs << kwargs
      original_structured_build.call(**kwargs)
    end
    Rag::AmbiguousModelResponder.define_singleton_method(:build) do |**kwargs|
      captured_kwargs << kwargs
      original_ambiguous_build.call(**kwargs)
    end
    Rag::DeterministicRenderer.define_singleton_method(:build) do |**kwargs|
      captured_kwargs << kwargs
      original_deterministic_build.call(**kwargs)
    end

    # None of the 3 builders match this question/scope, so execution falls
    # through to BedrockRagService#query — stub it so this test never reaches
    # the real network (it previously did, timing out against AWS Bedrock).
    rag_service = Object.new
    rag_service.define_singleton_method(:query) { |*| { answer: "ok", citations: [], session_id: "s" } }
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |**| rag_service }

    KbDocument.create!(account: accounts(:legacy), s3_key: "s3://bucket/soprel.pdf", display_name: "SOPREL", aliases: [])
    QueryOrchestratorService.new(
      "que es el Esquema SOPREL?",
      account: accounts(:legacy),
      entity_s3_uris: [ "s3://bucket/soprel.pdf" ],
      auto_scope_filter: true
    ).execute

    assert captured_kwargs.any?, "expected at least one route builder to be called"
    captured_kwargs.each do |kwargs|
      assert_not kwargs.key?(:auto_scope_filter),
                 "route builders must only see force_entity_filter, never auto_scope_filter"
    end
  ensure
    Rag::StructuredEvidenceRoute.define_singleton_method(:build) { |**kwargs| original_structured_build.call(**kwargs) } if original_structured_build
    Rag::AmbiguousModelResponder.define_singleton_method(:build) { |**kwargs| original_ambiguous_build.call(**kwargs) } if original_ambiguous_build
    Rag::DeterministicRenderer.define_singleton_method(:build) { |**kwargs| original_deterministic_build.call(**kwargs) } if original_deterministic_build
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
  end

  test "context evidence route receives the active episode" do
    episode = {
      "v" => 1,
      "episode_id" => "ep-context",
      "updated_at" => Time.current.iso8601,
      "facts" => { "model" => { "status" => "unknown_confirmed", "source" => "user" } }
    }
    session = Struct.new(:active_episode, :active_entities, :id).new(episode, {}, 42)
    service = QueryOrchestratorService.new(
      "Cómo se ajustan los resortes de la fijación de cables ?",
      account: accounts(:legacy), conv_session: session, output_channel: :web,
      session_context: "## Photo Evidence (this turn)\n- Component: Amarre"
    )
    captured = nil
    original_build = Rag::ContextEvidenceRoute.method(:build)
    Rag::ContextEvidenceRoute.define_singleton_method(:build) do |**kwargs|
      captured = kwargs
      nil
    end

    service.send(:context_evidence_result)

    assert_equal episode, captured[:episode]
    assert_equal "## Photo Evidence (this turn)\n- Component: Amarre", captured[:session_context]
  ensure
    if original_build
      Rag::ContextEvidenceRoute.define_singleton_method(:build) { |**kwargs| original_build.call(**kwargs) }
    end
  end

  def store_visual_observation!(photo, manufacturer: "KONE")
    FieldPhotoObservation.persist!(
      photo,
      FieldPhotoObservation.from_analysis(
        parsed: {
          "canonical_component" => "resortes",
          "manufacturer" => manufacturer,
          "model" => "UNKNOWN",
          "subsystem" => "DOOR_OPERATOR",
          "condition" => "DEGRADED",
          "visible_text" => [ "R1" ]
        },
        model_id: "claude-sonnet-5-5"
      )
    )
    photo.reload
  end

  def capture_pilot_usage_events
    log_output = StringIO.new
    logger = ActiveSupport::Logger.new(log_output)
    Rails.logger.broadcast_to(logger)
    yield
    log_output.string.lines.filter_map do |line|
      JSON.parse(line.split("[PILOT_USAGE] ", 2).last) if line.include?("[PILOT_USAGE]")
    end
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  JESUS_T3 = "Elemont Montacargas Hidraulico Modelo MH"
  JESUS_E_KEY = "bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf"
  JESUS_C_KEY = "bulk_uploads/1/2026-08-31/manual-cea15p.pdf"

  def jesus_t3_docs
    account = accounts(:legacy)
    elemont = KbDocument.create!(
      account: account,
      s3_key: JESUS_E_KEY,
      display_name: "Elemont Montacargas Hidraulico Modelo MH",
      aliases: [ "Modelo MH", "Elemont" ]
    )
    cea15 = KbDocument.create!(
      account: account,
      s3_key: JESUS_C_KEY,
      display_name: "manual-cea15p",
      aliases: [ "CEA15P", "CEA15+" ]
    )
    [ account, elemont, cea15 ]
  end

  def jesus_t3_session(elemont)
    uri = elemont.display_s3_uri(KbDocument::KB_BUCKET)
    Struct.new(:active_entities, :id).new(
      {
        elemont.display_name => {
          "source" => "user_pin",
          "kb_document_id" => elemont.id,
          "source_uri" => uri,
          "canonical_name" => elemont.display_name,
          "aliases" => elemont.aliases,
          "entity_type" => "document",
          "added_at" => Time.current.iso8601
        }
      },
      99
    )
  end

  test "jesus T3 qualifies as a document overview query" do
    _account, elemont, _cea15 = jesus_t3_docs
    names = [ elemont.display_name, *elemont.aliases ]
    assert Rag::DeterministicIntent.document_overview_query?(JESUS_T3, names)
  end

  test "jesus T3 builders stay nil even with force_entity_filter true" do
    account, elemont, cea15 = jesus_t3_docs
    uris = [
      elemont.display_s3_uri(KbDocument::KB_BUCKET),
      cea15.display_s3_uri(KbDocument::KB_BUCKET)
    ]
    sources = [ "document" ]

    assert_nil Rag::StructuredEvidenceRoute.build(
      question: JESUS_T3, account: account, entity_s3_uris: uris,
      entity_sources: sources, force_entity_filter: true,
      response_locale: :es, output_channel: :web
    )
    assert_nil Rag::AmbiguousModelResponder.build(
      question: JESUS_T3, account: account, entity_s3_uris: uris,
      entity_sources: sources, force_entity_filter: true,
      response_locale: :es
    )
    assert_nil Rag::DeterministicRenderer.build(
      question: JESUS_T3, entity_s3_uris: uris, entity_sources: sources,
      force_entity_filter: true, response_locale: :es, account: account
    )
  end

  test "jesus T3 with missing toc_v1 reaches Bedrock with forced episode URIs" do
    account, elemont, cea15 = jesus_t3_docs
    uris = [
      elemont.display_s3_uri(KbDocument::KB_BUCKET),
      cea15.display_s3_uri(KbDocument::KB_BUCKET)
    ]
    session = jesus_t3_session(elemont)
    captured = {}
    orig_download = S3DocumentsService.instance_method(:download)
    S3DocumentsService.define_method(:download) { |_key| nil }
    orig_query = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured[:question] = question
      captured[:kwargs] = kwargs
      { answer: "kb", citations: [], session_id: nil }
    end

    result = QueryOrchestratorService.new(
      JESUS_T3,
      account: account,
      conv_session: session,
      entity_s3_uris: uris,
      force_entity_filter: true,
      auto_scope_filter: true,
      output_channel: :web,
      session_context: "## Selection Turn\nActive problem from the previous user turn: \"La falla es en la puerta número 1 el equipo no magnetiza bien el imán de la puerta para que inicie movimiento.\""
    ).execute

    assert_equal JESUS_T3, captured[:question]
    assert_equal true, captured[:kwargs][:force_entity_filter]
    assert_equal uris, captured[:kwargs][:entity_s3_uris]
    assert_equal "kb", result[:answer]
    assert_not_equal "document_overview", result[:retrieval_trace].to_h["mode"]
  ensure
    S3DocumentsService.define_method(:download, orig_download) if orig_download
    BedrockRagService.define_method(:query, orig_query) if orig_query
  end

  test "explicit equipment identity is kept when the live episode changes" do
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "Orona",
      needles: [ "Orona", "PBCM-V3" ],
      facts: [
        { "slot" => "manufacturer", "value" => "Orona", "source" => "photo", "correlation_id" => "photo:a" },
        { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "photo:a" }
      ]
    )
    session = live_otis_session
    explicit = QueryOrchestratorService.new("pregunta", conv_session: session, equipment_identity: identity)
    supplied_nil = QueryOrchestratorService.new("pregunta", conv_session: session, equipment_identity: nil)
    derived = QueryOrchestratorService.new("pregunta", conv_session: session)

    assert_equal identity, explicit.send(:resolved_equipment_identity)
    assert_nil supplied_nil.send(:resolved_equipment_identity)
    assert_equal "OTIS", derived.send(:resolved_equipment_identity).manufacturer
  end

  test "a malformed explicit identity stays required and does not fall open" do
    open_calls = 0
    rag = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    rag.define_singleton_method(:retrieve_and_generate_with_retry) do |*|
      open_calls += 1
      flunk "open retrieve_and_generate"
    end
    rag.define_singleton_method(:retrieve_chunks) { |*| flunk "retrieve" }
    original_new = BedrockRagService.method(:new)
    original_overview = Rag::DocumentOverviewResponder.method(:build)
    original_ambiguous = Rag::AmbiguousModelResponder.method(:build)
    original_deterministic = Rag::DeterministicRenderer.method(:build)
    BedrockRagService.define_singleton_method(:new) { |**| rag }
    Rag::DocumentOverviewResponder.define_singleton_method(:build) { |**| flunk "overview" }
    Rag::AmbiguousModelResponder.define_singleton_method(:build) { |**| flunk "ambiguous" }
    Rag::DeterministicRenderer.define_singleton_method(:build) { |**| flunk "deterministic" }
    service = QueryOrchestratorService.new(
      "pregunta",
      account: accounts(:legacy),
      conv_session: live_otis_session,
      equipment_identity: { "manufacturer" => "Orona" },
      output_channel: :web
    )
    service.define_singleton_method(:skip_routing?) { false }
    service.define_singleton_method(:classify_query_intent) { QueryOrchestratorService::TOOLS[:HYBRID_QUERY] }
    service.define_singleton_method(:execute_hybrid_query) { flunk "hybrid" }

    assert service.send(:equipment_identity_required?)
    assert_equal :malformed, service.send(:resolved_equipment_identity)
    result = service.execute

    assert_equal "unavailable", result[:equipment_identity_status]
    assert_equal "malformed_identity", result[:equipment_identity_reason]
    assert_equal 0, open_calls
    assert_not_equal "OTIS", result[:answer]
  ensure
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    Rag::DocumentOverviewResponder.define_singleton_method(:build) { |**kwargs| original_overview.call(**kwargs) } if original_overview
    Rag::AmbiguousModelResponder.define_singleton_method(:build) { |**kwargs| original_ambiguous.call(**kwargs) } if original_ambiguous
    Rag::DeterministicRenderer.define_singleton_method(:build) { |**kwargs| original_deterministic.call(**kwargs) } if original_deterministic
  end

  test "known equipment skips terminals that do not apply the compatibility policy" do
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "Orona",
      needles: [ "Orona" ],
      facts: [
        { "slot" => "manufacturer", "value" => "Orona", "source" => "photo", "correlation_id" => "photo:a" }
      ]
    )
    original_overview = Rag::DocumentOverviewResponder.method(:build)
    original_ambiguous = Rag::AmbiguousModelResponder.method(:build)
    original_deterministic = Rag::DeterministicRenderer.method(:build)
    original_query = BedrockRagService.instance_method(:query)
    Rag::DocumentOverviewResponder.define_singleton_method(:build) { |**| flunk "overview" }
    Rag::AmbiguousModelResponder.define_singleton_method(:build) { |**| flunk "ambiguous" }
    Rag::DeterministicRenderer.define_singleton_method(:build) { |**| flunk "deterministic" }
    BedrockRagService.define_method(:query) do |_question, **|
      { answer: "cerrado", citations: [], equipment_identity_status: "no_compatible" }
    end
    service = QueryOrchestratorService.new(
      "pregunta",
      account: accounts(:legacy),
      equipment_identity: identity,
      output_channel: :web
    )
    service.define_singleton_method(:skip_routing?) { false }
    service.define_singleton_method(:classify_query_intent) { QueryOrchestratorService::TOOLS[:HYBRID_QUERY] }
    service.define_singleton_method(:execute_hybrid_query) { flunk "hybrid" }

    result = service.execute

    assert_equal "cerrado", result[:answer]
    assert_equal "no_compatible", result[:equipment_identity_status]
  ensure
    Rag::DocumentOverviewResponder.define_singleton_method(:build) { |**kwargs| original_overview.call(**kwargs) } if original_overview
    Rag::AmbiguousModelResponder.define_singleton_method(:build) { |**kwargs| original_ambiguous.call(**kwargs) } if original_ambiguous
    Rag::DeterministicRenderer.define_singleton_method(:build) { |**kwargs| original_deterministic.call(**kwargs) } if original_deterministic
    BedrockRagService.define_method(:query, original_query) if original_query
  end

  def live_otis_session
    Object.new.tap do |session|
      session.define_singleton_method(:active_episode) do
        {
          "v" => 1,
          "episode_id" => "ep-b",
          "updated_at" => Time.current.iso8601,
          "facts" => {
            "manufacturer" => {
              "value" => "OTIS", "status" => "known", "source" => "user", "correlation_id" => "case:b"
            }
          },
          "identifiers" => []
        }
      end
      session.define_singleton_method(:id) { nil }
    end
  end
end
