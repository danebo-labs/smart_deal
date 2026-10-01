# frozen_string_literal: true

require "test_helper"
require "ostruct"

class FieldPhotoAnalysisJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper
  parallelize(workers: 1)

  class SpyMemoryStore < ActiveSupport::Cache::MemoryStore
    attr_reader :read_names, :write_names

    def initialize(*)
      super
      @read_names = []
      @write_names = []
    end

    def read(name, ...)
      @read_names << name.to_s
      super
    end

    def write(name, value, ...)
      @write_names << name.to_s
      super
    end
  end

  class RecordingVisionClient
    attr_reader :calls

    def initialize(text)
      @text = text
      @calls = []
    end

    def call(**kwargs)
      @calls << kwargs
      {
        text: @text,
        usage: OpenStruct.new(input_tokens: 120, output_tokens: 80),
        model: BatchChunkingPrompt::MODEL_TEXT
      }
    end
  end

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
    Rails.cache = SpyMemoryStore.new
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

  test "a fresh photo is analyzed once, broadcast, and never ingested" do
    calls = 0
    events = capture_pilot_usage_events do
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
        assert_equal analysis_result[:analysis], messages.last["summary"]
        history = @session.reload.conversation_history.last
        assert_equal analysis_result[:compact_context], history["content"]
        assert_equal users(:one).id, history["user_id"]
        assert_equal "photo:job-test", history["correlation_id"]
        assert_nil FieldPhotoPendingImageStore.take(token: @token, account_id: accounts(:legacy).id)
        assert_no_enqueued_jobs only: [ BedrockIngestionJob, SubmitManualBatchJob ]
      end
    end

    assert_no_diagnosis_cache_access
    assert_not_includes events.pluck("event"), "photo_cache_hit"
    completed = events.find { |event| event["event"] == "photo_completed" }
    assert_not completed.key?("cache_status")
  end

  test "the same sha is read twice and the second question reaches vision" do
    calls = 0
    captured = []
    events = capture_pilot_usage_events do
      with_analysis_service(result: analysis_result, on_call: -> { calls += 1 }, captured: captured) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "cómo se ajusta el resorte"))
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(image_token: pending_token, question: "mira la polea"))
      end
    end

    assert_equal 2, calls
    assert_equal "cómo se ajusta el resorte", captured[0].dig(:photo_intent, "text")
    assert_equal "question", captured[0].dig(:photo_intent, "source")
    assert_equal "mira la polea", captured[1].dig(:photo_intent, "text")
    assert_not_includes events.pluck("event"), "photo_cache_hit"
    assert_not_includes events.pluck("event"), "visual_llm_call_avoided"
    assert_not_includes events.pluck("event"), "photo_cache_miss"
    completed = events.select { |event| event["event"] == "photo_completed" }
    assert_equal 2, completed.size
    assert completed.none? { |event| event.key?("cache_status") }
    assert_no_diagnosis_cache_access
  end

  test "a second user still gets one fresh vision call and the history is attributed to them" do
    second_user = User.create!(email: "a2@example.com", password: "password123", account: accounts(:legacy))
    calls = 0
    events = capture_pilot_usage_events do
      with_analysis_service(result: analysis_result, on_call: -> { calls += 1 }) do
        FieldPhotoAnalysisJob.perform_now(
          **job_args.merge(user_id: second_user.id, correlation_id: "photo:a2")
        )
      end
    end

    assert_equal 1, calls
    history = @session.reload.conversation_history.last
    assert_equal second_user.id, history["user_id"]
    assert_equal "photo:a2", history["correlation_id"]
    assert_not_includes events.pluck("event"), "photo_cache_hit"
    assert_not_includes events.pluck("event"), "visual_llm_call_avoided"
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

  test "persists a FieldPhoto on a fresh read" do
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

  # CG-D19: a photo with a question is one answer. No vision card, no
  # placeholder, one broadcast; both turns still land in the history.
  test "flag on with a question delivers one answer broadcast and both turns land in history" do
    set_photo_question_flag("true")
    orig_query = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      { answer: "Es un panel de control", citations: [], session_id: nil }
    end

    with_analysis_service(result: analysis_result) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "Que es esto?"))
      end

      assert_equal [ "photo_question_answered" ], messages.pluck("status")
      answer_message = messages.last
      assert_equal "Es un panel de control", answer_message["answer"]
      assert_equal "photo:job-test", answer_message["correlation_id"]
      assert answer_message.key?("field_photo_id")
      assert_not answer_message.key?("visual_summary")
      assert_not answer_message.key?("pending_question")
      assert_not answer_message.key?("presentation")

      history = @session.reload.conversation_history
      assert_equal analysis_result[:compact_context], history[-2]["content"]
      assert_equal "Es un panel de control", history[-1]["content"]
      assert_equal 1, history.count { |turn| turn["content"] == "Es un panel de control" }
    end
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
    set_photo_question_flag(nil)
  end

  test "an explicit photo question reaches vision and still delivers one RAG answer" do
    set_photo_question_flag("true")
    question = "Cómo se ajustan los resortes de la fijación de cables"
    service_calls = 0
    answer_service = Object.new
    answer_service.define_singleton_method(:call) do
      service_calls += 1
      { answer: "Respuesta de manual", citations: [], generation_mode: "test" }
    end
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| answer_service }

    messages = nil
    with_vision_client(vision_json) do |client|
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: question))
      end

      assert_equal 1, client.calls.size
      intent = client.calls.first[:user_content].reverse.find { |block| block[:type] == "text" }[:text]
      assert_includes intent, question
      assert_includes intent, "target_visible"
    end

    assert_equal 1, service_calls
    assert_equal [ "photo_question_answered" ], messages.pluck("status")
    assert_equal "Respuesta de manual", messages.last["answer"]
  ensure
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    set_photo_question_flag(nil)
  end

  test "a blank photo with inherited intent gives best effort guidance in one vision call and skips RAG" do
    set_photo_question_flag("true")
    spring = "Cómo se ajustan los resortes de la fijación de cables"
    @session.update!(
      active_episode: live_episode(goal: "si te doy otra imagen"),
      conversation_history: [ user_turn(spring, 20.minutes.ago) ]
    )
    service_calls = 0
    answer_service = Object.new
    answer_service.define_singleton_method(:call) { service_calls += 1; { answer: "no", citations: [] } }
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| answer_service }
    useful_summary = "Con esta vista se ven terminales roscados con resortes. Como revisión visual, compara la compresión y la posición de las tuercas entre cables. La foto no permite confirmar un valor de ajuste."
    missing = "Si puedes, una foto más abierta del conjunto ayudaría a afinar la identificación."

    messages = nil
    with_vision_client(vision_json(
      "summary" => useful_summary,
      "target_visible" => true,
      "relevance_to_goal" => "relevant",
      "missing_view_or_detail" => missing
    )) do |client|
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args)
      end

      assert_equal 1, client.calls.size
      intent = client.calls.first[:user_content].reverse.find { |block| block[:type] == "text" }[:text]
      assert_includes intent, spring
      assert_includes intent, "fijación"
      assert_not_includes intent, "otra imagen"
    end

    assert_equal 0, service_calls
    assert_equal [ "photo_analyzed" ], messages.pluck("status")
    summary = messages.last["summary"]
    assert summary.start_with?(I18n.t("rag.photo_intent.target_visible", locale: :es))
    assert_includes summary, "terminales roscados con resortes"
    assert_includes summary, "compara la compresión"
    assert_includes summary, "no permite confirmar un valor de ajuste"
    assert_includes summary, "Si puedes"
    assert_not_includes summary, "No encontré"
    assert_not_includes summary, "antes de poder ayudarte"
  ensure
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    set_photo_question_flag(nil)
  end

  test "a blank photo with an expired episode stays a standalone reading" do
    @session.update!(
      active_episode: {
        "v" => 1,
        "episode_id" => "ep_expired",
        "opened_at" => 6.hours.ago.iso8601,
        "updated_at" => 5.hours.ago.iso8601,
        "goal" => { "text" => "ajusta los resortes", "correlation_id" => "query:old", "truncated" => false }
      },
      conversation_history: [ user_turn("ajusta los resortes de la fijación", 6.hours.ago) ]
    )

    messages = nil
    with_vision_client(vision_json) do |client|
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args)
      end

      assert_equal 1, client.calls.size
      texts = client.calls.first[:user_content].select { |block| block[:type] == "text" }.pluck(:text)
      assert texts.none? { |text| text.include?("Photo intent") }
    end

    summary = messages.last["summary"]
    assert summary.start_with?("Se ve un conjunto de cabina y puerta.")
    assert_not summary.start_with?(I18n.t("rag.photo_intent.target_hidden_default", locale: :es))
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

  test "an exception in the photo-question RAG delivers one failed answer that carries the paid visual reading" do
    set_photo_question_flag("true")
    orig_call = Rag::PhotoQuestionAnswerService.instance_method(:call)
    Rag::PhotoQuestionAnswerService.define_method(:call) { raise RuntimeError, "boom" }

    with_analysis_service(result: analysis_result) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "Que es esto?"))
      end

      assert_equal [ "photo_question_answered" ], messages.pluck("status")
      answer_message = messages.last
      assert_equal I18n.t("rag.photo_question_unavailable", locale: :es), answer_message["answer"]
      assert_equal analysis_result[:analysis], answer_message["visual_summary"]

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
      owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:job-test")
      with_analysis_service(result: analysis_result) do
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
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
      owner = @session.live_episode_id
      @session.record_assistant_turn!(
        "… ¿Qué marca y modelo es el equipo?", user_id: users(:one).id, correlation_id: "query:2", expected_episode_id: owner
      )
      @session.record_user_turn!("Fuji Yida", user_id: users(:one).id, correlation_id: "query:3")
      @session.record_assistant_turn!(
        "… ¿Sabes el modelo?", user_id: users(:one).id, correlation_id: "query:4", expected_episode_id: owner
      )
      @session.record_user_turn!("el modelo no lo sé", user_id: users(:one).id, correlation_id: "query:5")

      kone = analysis_result
      kone[:parsed] = kone[:parsed].merge("manufacturer" => "KONE", "model" => "UNKNOWN")
      with_analysis_service(result: kone) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
      end
    end

    episode = @session.reload.active_episode
    assert_equal "Fuji Yida", episode.dig("facts", "manufacturer", "value")
    assert_equal "unknown_confirmed", episode.dig("facts", "model", "status")
    assert_equal "KONE", episode["conflicts"].first["photo"]
    assert_equal @sha, episode.dig("active_photo", "sha256")
  end

  test "photo_completed cost for the audited sonnet 4.6 vector is 0.014085" do
    audited = analysis_result.merge(
      model: "claude-sonnet-4-6",
      usage: { input_tokens: 1430, output_tokens: 360, cache_creation_tokens: 1172 }
    )
    events = capture_pilot_usage_events do
      with_analysis_service(result: audited) do
        FieldPhotoAnalysisJob.perform_now(**job_args)
      end
    end

    completed = events.find { |event| event["event"] == "photo_completed" }
    expected = BedrockQuery.new(
      model_id: "claude-sonnet-4-6-direct",
      input_tokens: 1430,
      output_tokens: 360,
      cache_creation_tokens: 1172
    ).cost
    assert_equal 0.014085, expected
    assert_equal expected, completed["cost"]
  end

  test "a live vision call is one visual_query row and photo_completed matches that cost" do
    events = nil
    with_anthropic_vision(input_tokens: 1430, output_tokens: 360, cache_creation_tokens: 1172) do
      assert_enqueued_jobs 1, only: TrackBedrockQueryJob do
        events = capture_pilot_usage_events do
          FieldPhotoAnalysisJob.perform_now(**job_args)
        end
      end
    end

    job = enqueued_jobs.find { |entry| entry[:job] == TrackBedrockQueryJob }
    args = job.fetch(:args).last.to_h.symbolize_keys
    assert_equal "query", args[:source]
    assert_equal "visual_query", args[:route]
    assert_equal 1430, args[:input_tokens]
    assert_equal 1172, args[:cache_creation_tokens]
    assert_equal "claude-sonnet-5-5-direct", args[:model_id]
    assert_equal 1, enqueued_jobs.count { |entry| entry[:job] == TrackBedrockQueryJob }
    assert enqueued_jobs.none? { |entry|
      entry[:job] == TrackBedrockQueryJob && entry.fetch(:args).last.to_h.symbolize_keys[:source] == "semantic_analysis"
    }

    expected = BedrockQuery.new(
      model_id: "claude-sonnet-5-5-direct",
      input_tokens: 1430,
      output_tokens: 360,
      cache_creation_tokens: 1172
    ).cost
    completed = events.find { |event| event["event"] == "photo_completed" }
    assert_equal expected, completed["cost"]
  end

  test "the same bytes twice enqueue two visual rows and no semantic row" do
    with_anthropic_vision(input_tokens: 100, output_tokens: 20) do
      FieldPhotoAnalysisJob.perform_now(**job_args)
      FieldPhotoAnalysisJob.perform_now(**job_args.merge(image_token: pending_token))
    end

    visual = enqueued_jobs.select { |entry| entry[:job] == TrackBedrockQueryJob }
    assert_equal 2, visual.size
    assert visual.all? { |entry|
      payload = entry[:args].last
      (payload[:route] || payload["route"]) == "visual_query" &&
        (payload[:source] || payload["source"]) == "query"
    }
  end

  test "turn evidence uses the transmitted photo text and the same outcome" do
    result = analysis_result.merge(target_visible: false)
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    messages = nil
    with_analysis_service(result: result) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args)
      end
    end

    evidence = turn_evidence_payloads(output).sole
    completed = output.string.lines.map { |line|
      JSON.parse(line.split("[PILOT_USAGE] ", 2).last) if line.include?('"interaction_completed"')
    }.compact.sole
    summary = messages.last["summary"]
    assert_equal "answered", completed["outcome"]
    assert_equal completed["outcome"], evidence["outcome"]
    assert_equal completed["correlation_id"], evidence["correlation_id"]
    assert_equal Digest::SHA256.hexdigest(""), evidence["original_query_sha256"]
    assert_equal Digest::SHA256.hexdigest(summary), evidence["answer_sha256"]
    assert_equal false, evidence.dig("photo", "target_visible")
    assert_not evidence.key?("answer")
    assert_not evidence.key?("cost")
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "a photo question attributes the transmitted answer and the controller outcome" do
    transmitted = "No encontré ese dato en la documentación."
    set_photo_question_flag("true")
    original = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) do |**|
      service = Object.new
      service.define_singleton_method(:call) do
        {
          answer: transmitted,
          citations: [],
          retrieved_citations: [
            { chunk_sha256: "chunk-photo", metadata: { "canonical_name" => "Manual", "page_number" => 2 } }
          ],
          effective_query: "pregunta efectiva",
          generation_mode: "generative"
        }
      end
      service
    end
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    with_analysis_service(result: analysis_result) do
      FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "cómo se ajusta el resorte"))
    end

    evidence = turn_evidence_payloads(output).sole
    completed = output.string.lines.filter_map { |line|
      JSON.parse(line.split("[PILOT_USAGE] ", 2).last) if line.include?('"interaction_completed"')
    }.sole
    assert_equal "abstained", completed["outcome"]
    assert_equal "abstained", evidence["outcome"]
    assert_equal Digest::SHA256.hexdigest(transmitted), evidence["answer_sha256"]
    assert_not_equal Digest::SHA256.hexdigest(analysis_result[:analysis]), evidence["answer_sha256"]
    assert_equal [ "chunk-photo" ], evidence["chunk_ids"]
    assert_equal Digest::SHA256.hexdigest("pregunta efectiva"), evidence["effective_query_sha256"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original.call(**kwargs) } if original
    set_photo_question_flag(nil)
  end

  test "a vision failure logs turn evidence for the transmitted error text" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    with_analysis_service(error: RuntimeError.new("provider details")) do
      perform_enqueued_jobs do
        FieldPhotoAnalysisJob.perform_later(**job_args.merge(question: "el resorte"))
      end
    end

    evidence = turn_evidence_payloads(output).sole
    completed = output.string.lines.filter_map { |line|
      JSON.parse(line.split("[PILOT_USAGE] ", 2).last) if line.include?('"interaction_completed"')
    }.sole
    failed_text = I18n.t("rag.photo_analysis_failed", locale: :es)
    assert_equal "failed", completed["outcome"]
    assert_equal "failed", evidence["outcome"]
    assert_equal Digest::SHA256.hexdigest(failed_text), evidence["answer_sha256"]
    assert_equal Digest::SHA256.hexdigest("el resorte"), evidence["original_query_sha256"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "expired and failed photo outcomes log turn evidence for the transmitted failure text" do
    FieldPhotoPendingImageStore.delete(token: @token, account_id: accounts(:legacy).id)
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    with_analysis_service(error: "must not be called") do
      FieldPhotoAnalysisJob.perform_now(**job_args.merge(question: "mira el resorte"))
    end
    expired = turn_evidence_payloads(output).sole
    expired_text = I18n.t("rag.photo_upload_expired", locale: :es)
    assert_equal "failed", expired["outcome"]
    assert_equal Digest::SHA256.hexdigest(expired_text), expired["answer_sha256"]
    assert_equal Digest::SHA256.hexdigest("mira el resorte"), expired["original_query_sha256"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "a fresh analysis stores the allowlisted observation and drops model prose" do
    with_analysis_service(result: complete_observation_result) do
      FieldPhotoAnalysisJob.perform_now(**job_args)
    end

    photo = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha)
    observation = photo.visual_observation
    assert_equal 1, observation["schema_version"]
    assert_equal FieldPhotoPrompt.prompt_fingerprint_sha256, observation["prompt_fingerprint"]
    assert_equal "claude-sonnet-5-5", observation["model_id"]
    assert_equal "KONE", observation["manufacturer"]
    assert_equal [ "R1" ], observation["visible_text"]
    assert_not observation.key?("summary")
    assert_not observation.key?("aliases")
    assert_not observation.key?("anti_hallucination_notes")
    assert_operator JSON.generate(observation).bytesize, :<=, 2048
  end

  test "new image bytes replace the stored observation instead of reusing it" do
    photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: @sha,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{@sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 4,
      visual_observation: { "manufacturer" => "OTIS", "summary" => "vieja" }
    )
    calls = 0

    with_analysis_service(result: complete_observation_result, on_call: -> { calls += 1 }) do
      FieldPhotoAnalysisJob.perform_now(**job_args.merge(field_photo_id: photo.id))
    end

    assert_equal 1, calls
    assert_equal "KONE", photo.reload.visual_observation["manufacturer"]
    assert_not photo.visual_observation.key?("summary")
  end

  test "a reread analyzes the same photo again and records photo_observation_reread" do
    photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: @sha,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{@sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 4,
      visual_observation: { "manufacturer" => "OTIS" }
    )
    FieldPhotoPendingImageStore.delete(token: @token, account_id: accounts(:legacy).id)
    calls = 0

    events = capture_pilot_usage_events do
      with_analysis_service(result: complete_observation_result, on_call: -> { calls += 1 }) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(
          image_token: nil,
          field_photo_id: photo.id,
          continuity: "reread",
          question: "revisa otra vez la foto"
        ))
      end
    end

    assert_equal 1, calls
    assert_equal [ photo.s3_key_original ], fake_s3.downloads
    assert_equal "KONE", photo.reload.visual_observation["manufacturer"]
    reread = events.find { |event| event["event"] == "photo_observation_reread" }
    assert_equal "reread", reread["cache_status"]
    assert_equal @sha.first(12), reread["image_digest_prefix"]
    assert_equal "photo:job-test", reread["correlation_id"]
  end

  test "reuse does not call Anthropic and keeps a technician manufacturer" do
    photo = create_observed_photo(manufacturer: "KONE")
    calls = 0
    set_photo_question_flag(nil)

    events = capture_pilot_usage_events do
      with_episode_flag("true") do
        with_analysis_service(result: complete_observation_result, on_call: -> { calls += 1 }) do
          @session.record_user_turn!("Cómo se ajustan los resortes de la fijación de cables ?", user_id: users(:one).id, correlation_id: "query:1")
          owner = @session.live_episode_id
          @session.record_assistant_turn!(
            "… ¿Qué marca y modelo es el equipo?", user_id: users(:one).id, correlation_id: "query:2", expected_episode_id: owner
          )
          @session.record_user_turn!("Fuji Yida", user_id: users(:one).id, correlation_id: "query:3")
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(
            image_token: nil,
            field_photo_id: photo.id,
            image_sha256: photo.sha256,
            continuity: "reuse",
            question: "estos resortes",
            expected_episode_id: owner
          ))
        end
      end
    end

    assert_equal 0, calls
    assert_empty fake_s3.downloads
    episode = @session.reload.active_episode
    assert_equal "Fuji Yida", episode.dig("facts", "manufacturer", "value")
    assert_equal "user", episode.dig("facts", "manufacturer", "source")
    assert_equal "KONE", episode["conflicts"].first["photo"]
    assert_equal "Fuji Yida", episode["conflicts"].first["user"]
    notice = Rag::FocusNotice.identity_conflict(session: @session)
    assert_includes notice.message, "Fuji Yida"
    assert_includes notice.message, "KONE"
    photo_state = episode["active_photo"]
    assert_equal photo.id, photo_state["field_photo_id"]
    assert_equal photo.sha256, photo_state["sha256"]
    assert_equal "photo:job-test", photo_state["correlation_id"]
    assert_nil photo_state["visual_observation"]
    assert_nil photo_state["summary"]
    reused = events.find { |event| event["event"] == "photo_observation_reused" }
    assert_equal "reused", reused["cache_status"]
    assert_equal "KONE", photo.reload.visual_observation["manufacturer"]
  end

  test "reuse injects the stored observation into the photo question and does not call Anthropic" do
    photo = create_observed_photo(manufacturer: "KONE")
    set_photo_question_flag("true")
    calls = 0
    captured = {}
    orig_query = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) do |_question, **kwargs|
      captured.replace(kwargs)
      { answer: "Respuesta de manual", citations: [], session_id: nil }
    end

    with_analysis_service(result: complete_observation_result, on_call: -> { calls += 1 }) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(
          image_token: nil,
          field_photo_id: photo.id,
          image_sha256: photo.sha256,
          continuity: "reuse",
          question: "estos resortes"
        ))
      end

      assert_equal 0, calls
      assert_equal "Respuesta de manual", messages.last["answer"]
      assert_equal [ "DANEBO_GUIDANCE" ], messages.last["provenance_segments"].pluck("band")
      assert_not_includes messages.last["provenance_segments"].to_json, "KONE"
    end

    assert_includes captured[:session_context], "Photo Evidence"
    assert_includes captured[:session_context], "KONE"
    assert_includes captured[:session_context], "resortes"
    assert_not_includes captured[:session_context], "no guardar"
    assert_equal "KONE", photo.reload.visual_observation["manufacturer"]
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
    set_photo_question_flag(nil)
  end

  test "reuse of another account photo does not reveal its observation" do
    foreign = create_observed_photo(account: accounts(:climb), manufacturer: "OTIS-SECRET")
    calls = 0

    with_analysis_service(result: complete_observation_result, on_call: -> { calls += 1 }) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(
          image_token: nil,
          field_photo_id: foreign.id,
          continuity: "reuse",
          question: "según la foto"
        ))
      end

      assert_equal 0, calls
      assert_equal Rag::PhotoObservationContinuity::MISSING_PHOTO_MESSAGE, messages.last["answer"]
      assert_not_includes messages.last["answer"], "OTIS-SECRET"
      assert messages.last["provenance_segments"].all? { |segment| segment["band"] == "DANEBO_GUIDANCE" }
      assert_not_includes messages.last["provenance_segments"].to_json, "OTIS-SECRET"
    end

    assert_equal "OTIS-SECRET", foreign.reload.visual_observation["manufacturer"]
  end

  test "a photo owned by case A does not write case B and still broadcasts" do
    opening = "Cómo se ajustan los resortes de la fijación de cables ?"
    reply = analysis_result[:compact_context]
    with_episode_flag("true") do
      @session.record_user_turn!(opening, user_id: users(:one).id, correlation_id: "query:1")
      owner = @session.live_episode_id
      @session.record_user_turn!(
        "Ahora estoy revisando un KONE que no nivela en planta 3",
        user_id: users(:one).id,
        correlation_id: "query:2"
      )
      later = @session.live_episode_id
      assert_not_equal owner, later

      events = capture_pilot_usage_events do
        with_analysis_service(result: analysis_result) do
          messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
            FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
          end
          assert_equal "photo_analyzed", messages.last["status"]
        end
      end

      episode = @session.reload.active_episode
      assert_equal later, episode["episode_id"]
      assert_nil episode["active_photo"]
      assert_equal "KONE", episode.dig("facts", "manufacturer", "value")
      assert_equal "user", episode.dig("facts", "manufacturer", "source")
      assert_nil episode.dig("facts", "model")
      assert_not_includes @session.conversation_history.pluck("content"), reply
      assert events.any? { |event| event["event"] == "photo_completed" }
    end
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

  def complete_observation_result
    analysis_result.merge(
      model: "claude-sonnet-5-5",
      canonical_name: "resortes",
      parsed: {
        "canonical_component" => "resortes",
        "manufacturer" => "KONE",
        "model" => "UNKNOWN",
        "subsystem" => "DOOR_OPERATOR",
        "condition" => "DEGRADED",
        "visible_text" => [ "R1" ],
        "summary" => "no guardar",
        "aliases" => [ "muelle" ],
        "documented_functions" => [],
        "anti_hallucination_notes" => "nota",
        "target_visible" => true,
        "relevance_to_goal" => "relevant"
      }
    )
  end

  def create_observed_photo(account: accounts(:legacy), manufacturer: "KONE")
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: account,
      sha256: sha,
      s3_key_original: "field_photos/#{account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg",
      byte_size: 8
    )
    FieldPhotoObservation.persist!(
      photo,
      FieldPhotoObservation.from_analysis(
        parsed: complete_observation_result[:parsed].merge("manufacturer" => manufacturer),
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

  def with_analysis_service(result: nil, error: nil, on_call: nil, captured: nil)
    original = FieldPhotoAnalysisService.method(:new)
    FieldPhotoAnalysisService.define_singleton_method(:new) do |**kwargs|
      captured << kwargs if captured
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

  def turn_evidence_payloads(output)
    output.string.lines.filter_map do |line|
      JSON.parse(line.split("[TURN_EVIDENCE] ", 2).last) if line.include?("[TURN_EVIDENCE]")
    end
  end

  def with_anthropic_vision(input_tokens:, output_tokens:, cache_creation_tokens: nil, text: nil)
    original = Anthropic::Client.method(:new)
    body = text || vision_json
    Anthropic::Client.define_singleton_method(:new) do |**|
      messages = Object.new
      messages.define_singleton_method(:stream) do |_params|
        usage = { input_tokens: input_tokens, output_tokens: output_tokens }
        usage[:cache_creation_input_tokens] = cache_creation_tokens if cache_creation_tokens
        OpenStruct.new(
          accumulated_message: OpenStruct.new(
            content: [ OpenStruct.new(type: "text", text: body) ],
            usage: OpenStruct.new(**usage),
            model: BatchChunkingPrompt::MODEL_TEXT,
            stop_reason: "end_turn"
          )
        )
      end
      OpenStruct.new(messages: messages)
    end
    yield
  ensure
    Anthropic::Client.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) } if original
  end

  def with_vision_client(text)
    client = RecordingVisionClient.new(text)
    original = ClaudeChunkingClient.method(:new)
    ClaudeChunkingClient.define_singleton_method(:new) { |**_| client }
    yield client
  ensure
    ClaudeChunkingClient.define_singleton_method(:new) { |**kwargs| original.call(**kwargs) } if original
  end

  def vision_json(extra = {})
    JSON.generate({
      "canonical_component" => "conjunto de cabina y puerta",
      "manufacturer" => "UNKNOWN",
      "model" => "UNKNOWN",
      "subsystem" => "UNKNOWN",
      "condition" => "UNKNOWN",
      "aliases" => [],
      "summary" => "Se ve un conjunto de cabina y puerta.",
      "visible_text" => [],
      "documented_functions" => [],
      "documented_connections" => [],
      "documented_values" => [],
      "documented_warnings" => [],
      "anti_hallucination_notes" => "La lectura se limita a lo visible."
    }.merge(extra))
  end

  def live_episode(goal:)
    {
      "v" => 1,
      "episode_id" => "ep_live",
      "status" => "active",
      "opened_at" => 1.hour.ago.iso8601,
      "updated_at" => 5.minutes.ago.iso8601,
      "goal" => { "text" => goal, "correlation_id" => "query:goal", "truncated" => false }
    }
  end

  def user_turn(content, time)
    { "role" => "user", "content" => content, "ts" => time.iso8601 }
  end

  def diagnosis_prefix
    %w[photo dx].join("_")
  end

  def assert_no_diagnosis_cache_access
    assert Rails.cache.read_names.none? { |name| name.include?(diagnosis_prefix) }
    assert Rails.cache.write_names.none? { |name| name.include?(diagnosis_prefix) }
  end
end
