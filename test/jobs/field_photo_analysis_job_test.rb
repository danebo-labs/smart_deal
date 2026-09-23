# frozen_string_literal: true

require "test_helper"

class FieldPhotoAnalysisJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper
  parallelize(workers: 1)

  class FakeS3
    attr_reader :uploads, :downloads

    def initialize(upload_succeeds: true, download_binary: "jpeg")
      @upload_succeeds = upload_succeeds
      @download_binary = download_binary
      @uploads = []
      @downloads = []
    end

    def upload_binary(key, data, content_type)
      @uploads << { key: key, data: data, content_type: content_type }
      @upload_succeeds ? key : nil
    end

    def download(key)
      @downloads << key
      @download_binary
    end
  end

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @session = ConversationSession.create!(
      identifier: "field-photo-job",
      channel: "web",
      account: accounts(:legacy),
      user: users(:one),
      expires_at: 1.day.from_now
    )
    @sha = Digest::SHA256.hexdigest("jpeg")
    @token = pending_token
    @s3_holder = { fake: FakeS3.new }
    holder = @s3_holder
    @orig_s3_new = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { holder[:fake] }
  end

  teardown do
    Rails.cache = @previous_cache
    orig_s3_new = @orig_s3_new
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| orig_s3_new.call(*a, **kw) }
  end

  test "cache miss analyzes exactly once, caches, broadcasts, and never ingests" do
    calls = 0
    with_analysis_service(result: analysis_result, on_call: -> { calls += 1 }) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        assert_no_difference("KbDocument.count") do
          FieldPhotoAnalysisJob.perform_now(**job_args)
        end
      end

      assert_equal 1, calls
      assert_equal "photo_analyzed", messages.last["status"]
      assert_equal "photo:job-test", messages.last["correlation_id"]
      assert_equal "es", messages.last["response_locale"]
      history = @session.reload.conversation_history.last
      assert_equal analysis_result[:compact_context], history["content"]
      assert_equal users(:one).id, history["user_id"]
      assert_equal "photo:job-test", history["correlation_id"]
      assert FieldPhotoDiagnosisCache.read(account_id: accounts(:legacy).id, sha256: @sha, locale: "es")
      assert_nil FieldPhotoPendingImageStore.take(token: @token, account_id: accounts(:legacy).id)
      assert_no_enqueued_jobs only: [ BedrockIngestionJob, SubmitManualBatchJob ]
    end
  end

  test "cache hit broadcasts response_locale from the request locale" do
    FieldPhotoDiagnosisCache.write(
      account_id: accounts(:legacy).id,
      sha256: @sha,
      locale: "es",
      value: cache_value
    )

    with_analysis_service(error: "must not be called") do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args)
      end

      assert_equal "photo_analyzed", messages.last["status"]
      assert_equal "es", messages.last["response_locale"]
    end
  end

  test "cache hit for another user avoids the visual service and attributes reuse" do
    second_user = User.create!(email: "a2@example.com", password: "password123", account: accounts(:legacy))
    FieldPhotoDiagnosisCache.write(
      account_id: accounts(:legacy).id,
      sha256: @sha,
      locale: "es",
      value: cache_value
    )
    log_output = StringIO.new
    logger = ActiveSupport::Logger.new(log_output)
    Rails.logger.broadcast_to(logger)

    with_analysis_service(error: "must not be called") do
      FieldPhotoAnalysisJob.perform_now(
        **job_args.merge(image_token: nil, user_id: second_user.id, correlation_id: "photo:a2")
      )
    end

    history = @session.reload.conversation_history.last
    assert_equal second_user.id, history["user_id"]
    assert_equal "photo:a2", history["correlation_id"]
    events = log_output.string.lines.filter_map do |line|
      JSON.parse(line.split("[PILOT_USAGE] ", 2).last) if line.include?("[PILOT_USAGE]")
    end
    assert_includes events.pluck("event"), "photo_cache_hit"
    avoided = events.find { |event| event["event"] == "visual_llm_call_avoided" }
    cache_hit = events.find { |event| event["event"] == "photo_cache_hit" }
    assert_equal second_user.id, avoided["user_id"]
    assert_equal 0, avoided["cost"]
    assert_operator avoided["estimated_cost_avoided"], :>, 0
    assert_equal 250, cache_hit["original_latency_ms"]
    assert_operator cache_hit["latency_ms"], :>=, 0
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "cache populated after enqueue is rechecked inside the job" do
    FieldPhotoDiagnosisCache.write(
      account_id: accounts(:legacy).id,
      sha256: @sha,
      locale: "es",
      value: cache_value
    )

    with_analysis_service(error: "must not be called") do
      FieldPhotoAnalysisJob.perform_now(**job_args)
    end

    assert_equal "photo:job-test", @session.reload.conversation_history.last["correlation_id"]
  end

  test "expired temporary image broadcasts localized failure without invoking visual service" do
    FieldPhotoPendingImageStore.delete(token: @token, account_id: accounts(:legacy).id)

    with_analysis_service(error: "must not be called") do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args)
      end

      assert_equal "failed", messages.last["status"]
      assert_equal "photo_upload_expired", messages.last["reason"]
      assert_equal "photo:job-test", messages.last["correlation_id"]
      assert_equal I18n.t("rag.photo_upload_expired", locale: :es), messages.last["message"]
    end
  end

  test "service error deletes the payload and broadcasts one clean correlated failure" do
    calls = 0
    with_analysis_service(error: RuntimeError.new("provider details"), on_call: -> { calls += 1 }) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        perform_enqueued_jobs do
          FieldPhotoAnalysisJob.perform_later(**job_args)
        end
      end

      assert_equal 1, calls
      assert_equal "failed", messages.last["status"]
      assert_equal "photo_analysis_error", messages.last["reason"]
      assert_equal "photo:job-test", messages.last["correlation_id"]
      assert_not_includes messages.last["message"], "provider details"
      assert_nil FieldPhotoPendingImageStore.take(token: @token, account_id: accounts(:legacy).id)
    end
  end

  test "persists a FieldPhoto on cache-hit when a temporary token is present" do
    FieldPhotoDiagnosisCache.write(
      account_id: accounts(:legacy).id, sha256: @sha, locale: "es", value: cache_value
    )

    with_analysis_service(error: "must not be called") do
      FieldPhotoAnalysisJob.perform_now(**job_args)
    end

    photo = FieldPhoto.find_by(account_id: accounts(:legacy).id, sha256: @sha)
    assert photo
    assert_equal 1, fake_s3.uploads.size
  end

  test "persists a FieldPhoto on cache-miss" do
    with_analysis_service(result: analysis_result) do
      FieldPhotoAnalysisJob.perform_now(**job_args)
    end

    photo = FieldPhoto.find_by(account_id: accounts(:legacy).id, sha256: @sha)
    assert photo
    assert_equal 1, fake_s3.uploads.size
  end

  test "does not persist again when field_photo_id is already provided" do
    existing = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: @sha,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{@sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )

    with_analysis_service(result: analysis_result) do
      FieldPhotoAnalysisJob.perform_now(**job_args.merge(field_photo_id: existing.id))
    end

    assert_empty fake_s3.uploads
  end

  test "an S3 persistence failure does not block the photo_analyzed broadcast" do
    self.fake_s3 = FakeS3.new(upload_succeeds: false)

    with_analysis_service(result: analysis_result) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args)
      end

      assert_equal "photo_analyzed", messages.last["status"]
    end

    assert_nil FieldPhoto.find_by(account_id: accounts(:legacy).id, sha256: @sha)
  end

  test "rehydrates from S3 and analyzes when the pending store is empty but field_photo_id is present" do
    photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: @sha,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{@sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    FieldPhotoPendingImageStore.delete(token: @token, account_id: accounts(:legacy).id)

    calls = 0
    with_analysis_service(result: analysis_result, on_call: -> { calls += 1 }) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(field_photo_id: photo.id))
      end

      assert_equal 1, calls
      assert_equal "photo_analyzed", messages.last["status"]
      assert_equal [ photo.s3_key_original ], fake_s3.downloads
    end
  end

  test "serialized job arguments contain no image bytes or base64" do
    FieldPhotoAnalysisJob.perform_later(**job_args)

    serialized = enqueued_jobs.last[:args].to_json
    assert_not_includes serialized, Base64.strict_encode64("jpeg")
    assert_not_includes serialized, '"data"'
    assert_not_includes serialized, '"binary"'
  end

  # ============================================
  # PHOTO_QUESTION_RAG_ENABLED (photo + question, plan foto_mas_pregunta_rag)
  # ============================================

  test "flag on with a question delivers two broadcasts in order and both turns land in history" do
    set_photo_question_flag("true")
    orig_query = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      { answer: "Es un panel de control", citations: [], session_id: nil }
    end

    with_analysis_service(result: analysis_result) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "Que es esto?"))
      end

      vision_message, answer_message = messages.last(2)
      assert_equal "photo_analyzed", vision_message["status"]
      assert_equal true, vision_message["pending_question"]
      assert_not vision_message.key?("answer")
      assert_equal "photo_question_answered", answer_message["status"]
      assert_equal "Es un panel de control", answer_message["answer"]
      assert_equal vision_message["correlation_id"], answer_message["correlation_id"]

      history = @session.reload.conversation_history
      assert_equal analysis_result[:compact_context], history[-2]["content"]
      assert_equal "Es un panel de control", history[-1]["content"]
    end
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
    set_photo_question_flag(nil)
  end

  test "cache hit with a question skips vision and still delivers two broadcasts in order" do
    FieldPhotoDiagnosisCache.write(
      account_id: accounts(:legacy).id, sha256: @sha, locale: "es", value: cache_value
    )
    set_photo_question_flag("true")
    orig_query = BedrockRagService.instance_method(:query)
    calls = 0
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      calls += 1
      { answer: "Respuesta barata", citations: [], session_id: nil }
    end

    with_analysis_service(error: "must not be called") do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "Que es esto?"))
      end

      assert_equal 1, calls
      vision_message, answer_message = messages.last(2)
      assert_equal "photo_analyzed", vision_message["status"]
      assert_equal true, vision_message["pending_question"]
      assert_equal "photo_question_answered", answer_message["status"]
      assert_equal "Respuesta barata", answer_message["answer"]
      assert_equal vision_message["correlation_id"], answer_message["correlation_id"]
    end
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
    set_photo_question_flag(nil)
  end

  test "blank question broadcasts once without pending_question or answer" do
    set_photo_question_flag("true")
    orig_query = BedrockRagService.instance_method(:query)
    calls = 0
    BedrockRagService.define_method(:query) { |*| calls += 1; { answer: "x", citations: [], session_id: nil } }

    with_analysis_service(result: analysis_result) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args)
      end

      assert_equal 0, calls
      assert_equal 1, messages.size
      assert_equal "photo_analyzed", messages.last["status"]
      assert_not messages.last.key?("pending_question")
      assert_not messages.last.key?("answer")
    end
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
    set_photo_question_flag(nil)
  end

  test "flag off preserves current behavior even with a question present" do
    set_photo_question_flag(nil)
    orig_query = BedrockRagService.instance_method(:query)
    calls = 0
    BedrockRagService.define_method(:query) { |*| calls += 1; { answer: "x", citations: [], session_id: nil } }

    with_analysis_service(result: analysis_result) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "Que es esto?"))
      end

      assert_equal 0, calls
      assert_equal 1, messages.size
      assert_not messages.last.key?("pending_question")
      assert_not messages.last.key?("answer")
    end
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
  end

  test "an exception in the photo-question RAG delivers the vision bubble first, then a failed placeholder answer" do
    set_photo_question_flag("true")
    orig_call = Rag::PhotoQuestionAnswerService.instance_method(:call)
    Rag::PhotoQuestionAnswerService.define_method(:call) { raise RuntimeError, "boom" }

    with_analysis_service(result: analysis_result) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "Que es esto?"))
      end

      vision_message, answer_message = messages.last(2)
      assert_equal "photo_analyzed", vision_message["status"]
      assert_equal true, vision_message["pending_question"]
      assert_equal "photo_question_answered", answer_message["status"]
      assert_equal I18n.t("rag.photo_question_unavailable", locale: :es), answer_message["answer"]

      history = @session.reload.conversation_history
      assert_not_includes history.pluck("content"), I18n.t("rag.photo_question_unavailable", locale: :es)
    end
  ensure
    Rag::PhotoQuestionAnswerService.define_method(:call, orig_call) if orig_call
    set_photo_question_flag(nil)
  end

  test "interaction_completed outcome reflects the RAG answer, not the vision text" do
    set_photo_question_flag("true")
    orig_query = BedrockRagService.instance_method(:query)

    # RAG abstains, vision answered normally -> outcome must be abstained.
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      { answer: "DATA_NOT_AVAILABLE", citations: [], session_id: nil }
    end
    with_analysis_service(result: analysis_result) do
      events = capture_pilot_usage_events do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "Que es esto?", correlation_id: "photo:outcome-1"))
      end
      completed = events.find { |e| e["event"] == "interaction_completed" }
      assert_equal "abstained", completed["outcome"]
    end

    # RAG answers normally, vision text happens to contain the abstention
    # marker -> outcome must still be answered (computed on the RAG answer).
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      { answer: "Es un panel de control", citations: [], session_id: nil }
    end
    vision_with_marker = analysis_result.merge(analysis: "DATA_NOT_AVAILABLE")
    with_analysis_service(result: vision_with_marker) do
      events = capture_pilot_usage_events do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(
          image_token: pending_token, image_sha256: "sha-outcome-2",
          question: "Que es esto?", correlation_id: "photo:outcome-2"
        ))
      end
      completed = events.find { |e| e["event"] == "interaction_completed" }
      assert_equal "answered", completed["outcome"]
    end
    BedrockRagService.define_method(:query, orig_query)

    # The photo-question RAG call raises past its own isolation (see the
    # dedicated exception test above) -> outcome must be failed, not derived
    # from the vision text.
    orig_call = Rag::PhotoQuestionAnswerService.instance_method(:call)
    Rag::PhotoQuestionAnswerService.define_method(:call) { raise RuntimeError, "boom" }
    with_analysis_service(result: analysis_result) do
      events = capture_pilot_usage_events do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(
          image_token: pending_token, image_sha256: "sha-outcome-3",
          question: "Que es esto?", correlation_id: "photo:outcome-3"
        ))
      end
      completed = events.find { |e| e["event"] == "interaction_completed" }
      assert_equal "failed", completed["outcome"]
    end
    Rag::PhotoQuestionAnswerService.define_method(:call, orig_call)
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
    set_photo_question_flag(nil)
  end

  # Acceptance test for the reported defect: image + "qué está mostrando la
  # pantalla" used to silently discard the question. With the flag on, the
  # query Bedrock receives must be anchored to the catalog-resolved component
  # (GECB) and the second broadcast must carry the cited answer.
  test "image + question about the screen reaches Bedrock anchored to the catalog-resolved component" do
    KbDocument.create!(
      account: accounts(:legacy), s3_key: "uploads/urm.pdf", display_name: "Manual de URM",
      aliases: [ "GECB" ], document_uid: SecureRandom.uuid
    )
    set_photo_question_flag("true")
    orig_query = BedrockRagService.instance_method(:query)
    captured_question = nil
    BedrockRagService.define_method(:query) do |question, **_kwargs|
      captured_question = question
      { answer: "Muestra el estado del sistema GECB.", citations: [], session_id: nil }
    end

    gecb_result = analysis_result.merge(
      canonical_name: "GECB",
      parsed: analysis_result[:parsed].merge("visible_text" => [ "System=1", "Tools=2" ])
    )

    with_analysis_service(result: gecb_result) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "¿Qué está mostrando la pantalla?"))
      end

      assert_includes captured_question, "¿Qué está mostrando la pantalla?"
      assert_includes captured_question, "GECB"
      assert_equal "Muestra el estado del sistema GECB.", messages.last["answer"]
    end
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
    set_photo_question_flag(nil)
  end

  test "P1 a photo without a question writes active_photo and keeps the card" do
    with_episode_flag("true") do
      with_analysis_service(result: analysis_result) do
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
          FieldPhotoAnalysisJob.perform_now(**job_args)
        end
        assert_equal "photo_analyzed", messages.last["status"]
      end
    end

    episode = @session.reload.active_episode
    assert_equal @sha, episode.dig("active_photo", "sha256")
    assert episode.dig("active_photo", "field_photo_id").present?
    assert_nil episode.dig("facts", "fault_code")
    assert_equal analysis_result[:compact_context], @session.conversation_history.last["content"]
  end

  test "P5 a photo brand that disagrees with the technician is stored as a conflict" do
    opening = "Cómo se ajustan los resortes de la fijación de cables ?"
    with_episode_flag("true") do
      @session.record_user_turn!(opening, user_id: users(:one).id, correlation_id: "query:1")
      @session.record_assistant_turn!("… ¿Qué marca y modelo es el equipo?", user_id: users(:one).id, correlation_id: "query:2")
      @session.record_user_turn!("Fuji Yida", user_id: users(:one).id, correlation_id: "query:3")
      @session.record_assistant_turn!("… ¿Sabes el modelo?", user_id: users(:one).id, correlation_id: "query:4")
      @session.record_user_turn!("el modelo no lo sé", user_id: users(:one).id, correlation_id: "query:5")

      kone = analysis_result
      kone[:parsed] = kone[:parsed].merge("manufacturer" => "KONE", "model" => "UNKNOWN")
      with_analysis_service(result: kone) do
        FieldPhotoAnalysisJob.perform_now(**job_args)
      end
    end

    episode = @session.reload.active_episode
    assert_equal "Fuji Yida", episode.dig("facts", "manufacturer", "value")
    assert_equal "unknown_confirmed", episode.dig("facts", "model", "status")
    assert_equal "KONE", episode["conflicts"].first["photo"]
    assert_equal @sha, episode.dig("active_photo", "sha256")
  end

  private

  def with_episode_flag(value)
    previous = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous
  end

  def set_photo_question_flag(value)
    if value.nil?
      ENV.delete("PHOTO_QUESTION_RAG_ENABLED")
    else
      ENV["PHOTO_QUESTION_RAG_ENABLED"] = value
    end
  end

  def fake_s3
    @s3_holder[:fake]
  end

  def fake_s3=(value)
    @s3_holder[:fake] = value
  end

  def pending_token
    FieldPhotoPendingImageStore.write(
      binary: "jpeg",
      content_type: "image/jpeg",
      filename: "panel.jpg",
      account_id: accounts(:legacy).id
    )
  end

  def job_args
    {
      image_token: @token,
      image_sha256: @sha,
      filename: "panel.jpg",
      content_type: "image/jpeg",
      account_id: accounts(:legacy).id,
      user_id: users(:one).id,
      conversation_session_id: @session.id,
      locale: "es",
      correlation_id: "photo:job-test"
    }
  end

  def analysis_result
    {
      analysis: "Visible analysis",
      compact_context: "[FOTO] Componente: Panel | Fabricante: UNKNOWN",
      canonical_name: "Panel",
      aliases: [ "P1" ],
      parsed: {
        "manufacturer" => "UNKNOWN",
        "model" => "P1",
        "condition" => "GOOD",
        "visible_text" => [ "P1" ]
      },
      model: BatchChunkingPrompt::MODEL_TEXT,
      usage: { input_tokens: 120, output_tokens: 80 },
      latency_ms: 250
    }
  end

  def cache_value
    result = analysis_result
    result.slice(:analysis, :compact_context, :canonical_name, :aliases).merge(
      manufacturer: "UNKNOWN",
      model_visible: "P1",
      condition: "GOOD",
      visible_codes: [ "P1" ],
      model_id: "#{BatchChunkingPrompt::MODEL_TEXT}-direct",
      input_tokens: 120,
      output_tokens: 80,
      original_cost: 0.00156,
      latency_ms: 250,
      created_at: Time.current.iso8601,
      contract_version: FieldPhotoPrompt::CONTRACT_VERSION
    )
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

  def with_analysis_service(result: nil, error: nil, on_call: nil)
    original = FieldPhotoAnalysisService.method(:new)
    FieldPhotoAnalysisService.define_singleton_method(:new) do |**_kwargs|
      fake = Object.new
      fake.define_singleton_method(:call) do
        on_call&.call
        raise(error.is_a?(Exception) ? error : RuntimeError.new(error)) if error

        result
      end
      fake
    end
    yield
  ensure
    FieldPhotoAnalysisService.define_singleton_method(:new) { |**kwargs| original.call(**kwargs) }
  end
end
