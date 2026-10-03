# frozen_string_literal: true

require "test_helper"
require "ostruct"

class FieldPhotoAnalysisJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper
  parallelize(workers: 1)

  LEGACY_PHOTO_FOLLOW_UP = "la consulta anterioir , de eso estoy hablando y por eso te comparti la foto"
  SAME_TURN_PHOTO_QUESTION = "¿Qué ves y qué debería revisar primero?"
  YIDA_PROCEDURE = "Paso 11. Ajusta el interruptor de zona de nivelación Yida a 2,5 mm."
  BLT_PROCEDURE = "E18 fallo de nivelación. Compruebe el encoder BLT."

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
        assert_equal accepted_compact_context(analysis_result), history["content"]
        assert_not_equal analysis_result[:compact_context], history["content"]
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
    assert_equal "cómo se ajusta el resorte", captured[0].dig(:visual_task_context, "visual_task", "text")
    assert_equal "question", captured[0].dig(:visual_task_context, "visual_task", "source")
    assert_equal "mira la polea", captured[1].dig(:visual_task_context, "visual_task", "text")
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
    orig_call = Rag::PhotoQuestionAnswerService.instance_method(:call)
    Rag::PhotoQuestionAnswerService.define_method(:call) do
      { answer: "Es un panel de control", citations: [], provenance_segments: [], generation_mode: "test" }
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
      assert_equal accepted_compact_context(analysis_result), history[-2]["content"]
      assert_not_equal analysis_result[:compact_context], history[-2]["content"]
      assert_equal "Es un panel de control", history[-1]["content"]
      assert_equal 1, history.count { |turn| turn["content"] == "Es un panel de control" }
    end
  ensure
    Rag::PhotoQuestionAnswerService.define_method(:call, orig_call) if orig_call
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
      assert_includes intent, "recent_user_target"
      assert_not_includes intent, '"source":"goal"'
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
    orig_call = Rag::PhotoQuestionAnswerService.instance_method(:call)

    # RAG abstains, vision answered normally -> outcome must be abstained.
    Rag::PhotoQuestionAnswerService.define_method(:call) do
      { answer: "DATA_NOT_AVAILABLE", citations: [], provenance_segments: [], generation_mode: "test" }
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
    Rag::PhotoQuestionAnswerService.define_method(:call) do
      { answer: "Es un panel de control", citations: [], provenance_segments: [], generation_mode: "test" }
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

    # The photo-question RAG call raises past its own isolation (see the
    # dedicated exception test above) -> outcome must be failed, not derived
    # from the vision text.
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
  ensure
    Rag::PhotoQuestionAnswerService.define_method(:call, orig_call) if orig_call
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
      parsed: analysis_result[:parsed].merge(
        "canonical_component" => "GECB",
        "visible_text" => [ "System=1", "Tools=2" ]
      )
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
    assert_equal accepted_compact_context(analysis_result), @session.conversation_history.last["content"]
    assert_not_equal analysis_result[:compact_context], @session.conversation_history.last["content"]
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

      kone = analysis_result.merge(relevance_to_goal: "relevant", target_visible: true)
      kone[:parsed] = kone[:parsed].merge("manufacturer" => "KONE", "model" => "UNKNOWN", "relevance_to_goal" => "relevant", "target_visible" => true)
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
      assert_not_includes @session.conversation_history.pluck("content"), accepted_compact_context(analysis_result)
      assert events.any? { |event| event["event"] == "photo_completed" }
    end
  end

  test "owner delivery keeps an unresolved controller pending and closes a written manufacturer" do
    with_episode_flag("true") do
      isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
        owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:job-test")
        episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
        episode.pending_question = { "type" => "controller", "carry" => [ "Q2" ] }
        episode.pending_fact = { "subject" => "controller", "correlation_id" => "seed" }
        @session.update!(active_episode: episode.to_h)

        with_analysis_service(result: analysis_result.merge(relevance_to_goal: "relevant", target_visible: true)) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
        end
        kept = @session.reload.active_episode
        assert_equal "controller", kept.dig("pending_question", "type")
        assert_equal [ "Q2" ], kept.dig("pending_question", "carry")
        assert_equal "P1", kept.dig("facts", "model", "value")
        assert_equal "photo", kept.dig("facts", "model", "source")

        manufacturer = ConversationSession.create!(
          identifier: "field-photo-manufacturer", channel: "web", account: accounts(:legacy),
          user: users(:one), expires_at: 1.day.from_now
        )
        brand_owner = manufacturer.ensure_case_for_photo_submission!(correlation_id: "photo:brand")
        brand = Rag::ActiveEpisode.parse(manufacturer.reload.active_episode)
        brand.pending_question = { "type" => "manufacturer" }
        brand.pending_fact = { "subject" => "manufacturer", "correlation_id" => "seed" }
        manufacturer.update!(active_episode: brand.to_h)
        nice = analysis_result.merge(relevance_to_goal: "relevant", target_visible: true)
        nice[:parsed] = nice[:parsed].merge("manufacturer" => "NICE", "model" => "UNKNOWN", "relevance_to_goal" => "relevant", "target_visible" => true)
        with_analysis_service(result: nice) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(
            conversation_session_id: manufacturer.id, expected_episode_id: brand_owner, correlation_id: "photo:brand",
            image_sha256: Digest::SHA256.hexdigest("nice-jpeg"), image_token: pending_token
          ))
        end
        closed = manufacturer.reload.active_episode
        assert_equal "NICE", closed.dig("facts", "manufacturer", "value")
        assert_equal "photo", closed.dig("facts", "manufacturer", "source")
        assert_nil closed["pending_question"]
      end
    end
  end

  test "a captionless photo with a visual goal keeps a relevant reading for the follow-up" do
    with_episode_flag("true") do
      owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:alone-door")
      episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
      episode.assign_goal!("la puerta no cierra", correlation_id: "seed")
      @session.update!(active_episode: episode.to_h)
      context = Rag::VisualTaskContext.build(
        question: nil, episode_state: @session.active_episode, history: @session.conversation_history, now: Time.current
      )
      assert_equal "goal", context.visual_task["source"]

      with_vision_client(display_vision_json) do |client|
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
        assert_equal 1, client.calls.size
      end

      stored = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha).visual_observation
      assert_equal "relevant", stored["relevance_to_goal"]
      kept = @session.reload.active_episode
      assert_equal "NICE", kept.dig("facts", "manufacturer", "value")
      assert_equal "photo", kept.dig("facts", "manufacturer", "source")
      assert_equal "NICE3000", kept.dig("facts", "model", "value")
      assert_equal "photo", kept.dig("facts", "model", "source")

      context, query, generation = captionless_follow_up
      assert context.relevant?
      assert_includes context.query_terms, "E51"
      assert_includes query, "NICE3000"
      assert_includes query, "E51"
      assert_includes generation, "Photo Evidence for the active episode"
      assert_includes generation, "E51"
    end
  end

  test "a captionless photo with an active goal and no visual task can still be relevant" do
    with_episode_flag("true") do
      owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:alone-board")
      episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
      episode.assign_goal!("revisar el tablero", correlation_id: "seed")
      @session.update!(active_episode: episode.to_h)
      task_context = Rag::VisualTaskContext.build(
        question: nil, episode_state: @session.active_episode, history: [], now: Time.current
      )
      assert_nil task_context.visual_task
      assert task_context.relevance_anchor?

      messages = nil
      with_vision_client(display_vision_json) do |client|
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
        end
        assert_equal 1, client.calls.size
        block = client.calls.first[:user_content].reverse.find { |item| item[:type] == "text" }[:text]
        assert_includes block, "revisar el tablero"
        assert_includes block, "There is no visual task"
      end

      stored = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha).visual_observation
      assert_equal "relevant", stored["relevance_to_goal"]
      assert_nil stored["target_visible"]
      assert_equal "NICE3000", stored["model"]
      kept = @session.reload.active_episode
      assert_equal "NICE", kept.dig("facts", "manufacturer", "value")
      assert_equal "photo", kept.dig("facts", "manufacturer", "source")
      assert_equal "NICE3000", kept.dig("facts", "model", "value")
      assert_equal "photo", kept.dig("facts", "model", "source")
      summary = messages.last["summary"]
      assert_not summary.start_with?(I18n.t("rag.photo_intent.target_uncertain", locale: :es))
      assert_not summary.start_with?(I18n.t("rag.photo_intent.close_up_request", locale: :es))

      context, query, generation = captionless_follow_up
      assert context.relevant?
      assert_includes context.query_terms, "E51"
      assert_includes query, "NICE3000"
      assert_includes query, "E51"
      assert_includes generation, "Photo Evidence for the active episode"
    end
  end

  test "a captionless photo with no active work does not score relevance" do
    with_episode_flag("true") do
      owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:alone-empty")
      task_context = Rag::VisualTaskContext.build(
        question: nil, episode_state: @session.active_episode, history: [], now: Time.current
      )
      assert_equal "standalone", task_context.mode
      assert_not task_context.relevance_anchor?

      with_vision_client(display_vision_json) do |client|
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
        texts = client.calls.first[:user_content].select { |block| block[:type] == "text" }.pluck(:text)
        assert texts.none? { |text| text.include?("CONTEXT IS NOT EVIDENCE") }
      end

      stored = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha).visual_observation
      assert_nil stored["relevance_to_goal"]
      assert_nil stored["target_visible"]
      kept = @session.reload.active_episode
      assert_nil kept.dig("facts", "manufacturer")
      assert_nil kept.dig("facts", "model")

      context, query, generation = captionless_follow_up
      assert_not context.relevant?
      assert_empty context.query_terms
      assert_not_includes generation, "Photo Evidence"
    end
  end

  test "a leveling goal without a visual stem keeps a relevant plate and an unset target" do
    with_leveling_episode do |owner|
      messages = nil
      with_vision_client(orona_vision_json) do |client|
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
        end
        block = client.calls.first[:user_content].reverse.find { |item| item[:type] == "text" }[:text]
        assert_includes block, "no nivela en planta 3"
        assert_includes block, "CONTEXT IS NOT EVIDENCE"
        assert_includes block, "There is no visual task"
        assert_not_includes block, "Orona"
        assert_not_includes block, "PBCM-V3"
        assert_not_includes block, "visual_task"
      end

      stored = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha).visual_observation
      assert_equal "relevant", stored["relevance_to_goal"]
      assert_nil stored["target_visible"]
      assert_equal "Orona", stored["manufacturer"]
      assert_equal "PBCM-V3", stored["model"]
      kept = @session.reload.active_episode
      assert_equal "Orona", kept.dig("facts", "manufacturer", "value")
      assert_equal "photo", kept.dig("facts", "manufacturer", "source")
      assert_equal "PBCM-V3", kept.dig("facts", "model", "value")
      assert_equal "photo", kept.dig("facts", "model", "source")
      summary = messages.last["summary"]
      assert_not summary.start_with?(I18n.t("rag.photo_intent.target_uncertain", locale: :es))
      assert_not summary.start_with?(I18n.t("rag.photo_intent.target_hidden_default", locale: :es))
    end
  end

  test "pending controller is not a visual task and a relevant plate does not close that slot" do
    with_episode_flag("true") do
      isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
        owner = seed_pending!(type: "controller", carry: [ "Q2" ])
        with_vision_client(vision_json(
          "manufacturer" => "UNKNOWN",
          "model" => "MX-20",
          "subsystem" => "CONTROLLER_LOGIC",
          "relevance_to_goal" => "relevant",
          "target_visible" => true,
          "summary" => "Se ve una placa con el modelo MX-20."
        )) do |client|
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
          block = client.calls.first[:user_content].reverse.find { |item| item[:type] == "text" }[:text]
          assert_includes block, '"type":"controller"'
          assert_not_includes block, "visual_task"
          assert_not_includes block, "Q2"
        end

        stored = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha).visual_observation
        kept = @session.reload.active_episode
        assert_equal "relevant", stored["relevance_to_goal"]
        assert_nil stored["target_visible"]
        assert_equal "MX-20", kept.dig("facts", "model", "value")
        assert_equal "photo", kept.dig("facts", "model", "source")
        assert_nil kept.dig("facts", "controller")
        assert_equal "controller", kept.dig("pending_question", "type")
        assert_equal [ "Q2" ], kept.dig("pending_question", "carry")
      end
    end
  end

  test "a relevant plate closes only a pending manufacturer slot" do
    with_episode_flag("true") do
      isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
        owner = seed_pending!(type: "manufacturer")
        with_vision_client(vision_json(
          "manufacturer" => "NICE",
          "model" => "UNKNOWN",
          "subsystem" => "CONTROLLER_LOGIC",
          "relevance_to_goal" => "relevant",
          "target_visible" => true,
          "summary" => "Se ve la marca NICE."
        )) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(
            expected_episode_id: owner, correlation_id: "photo:pending-brand"
          ))
        end

        kept = @session.reload.active_episode
        assert_equal "NICE", kept.dig("facts", "manufacturer", "value")
        assert_equal "photo", kept.dig("facts", "manufacturer", "source")
        assert_nil kept["pending_question"]
        assert_nil kept["pending_fact"]
      end
    end
  end

  test "an unrelated plate does not close a pending manufacturer slot" do
    with_episode_flag("true") do
      isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
        owner = seed_pending!(type: "manufacturer")
        with_vision_client(vision_json(
          "manufacturer" => "Orona",
          "model" => "PBCM-V3",
          "subsystem" => "CONTROLLER_LOGIC",
          "relevance_to_goal" => "unrelated",
          "target_visible" => true,
          "summary" => "Se ve una placa que no corresponde a este trabajo."
        )) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(
            expected_episode_id: owner, correlation_id: "photo:pending-unrelated"
          ))
        end

        stored = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha).visual_observation
        kept = @session.reload.active_episode
        assert_equal "unrelated", stored["relevance_to_goal"]
        assert_nil stored["target_visible"]
        assert_nil kept.dig("facts", "manufacturer")
        assert_nil kept.dig("facts", "model")
        assert_equal "manufacturer", kept.dig("pending_question", "type")
      end
    end
  end

  test "a spring photo with a pending controller is described and does not close that slot" do
    with_episode_flag("true") do
      isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
        owner = seed_pending!(type: "controller", carry: [ "Q2" ])
        summary = "Se ve un conjunto de resortes de fijación."
        messages = nil
        with_vision_client(vision_json(
          "canonical_component" => "resortes de fijación",
          "manufacturer" => "UNKNOWN",
          "model" => "UNKNOWN",
          "summary" => summary,
          "relevance_to_goal" => "uncertain",
          "target_visible" => true
        )) do |client|
          messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
            FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
          end
          block = client.calls.first[:user_content].reverse.find { |item| item[:type] == "text" }[:text]
          assert_includes block, '"type":"controller"'
          assert_not_includes block, "visual_task"
        end

        kept = @session.reload.active_episode
        assert_includes messages.last["summary"], "resortes"
        assert_not messages.last["summary"].start_with?(I18n.t("rag.photo_intent.target_uncertain", locale: :es))
        assert_nil kept.dig("facts", "controller")
        assert_nil kept.dig("facts", "manufacturer")
        assert_equal "controller", kept.dig("pending_question", "type")
        assert_equal [ "Q2" ], kept.dig("pending_question", "carry")
        assert_equal "uncertain", FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha).visual_observation["relevance_to_goal"]
      end
    end
  end

  test "a rejected observation is display-only and has no technical consequences" do
    set_photo_question_flag("true")
    service_calls = 0
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| service_calls += 1 }
    rejected = rejected_result

    with_episode_flag("true") do
      owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:job-test")
      episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
      episode.pending_question = { "type" => "manufacturer" }
      episode.pending_fact = { "subject" => "manufacturer", "correlation_id" => "seed" }
      @session.update!(active_episode: episode.to_h)

      events = nil
      messages = nil
      with_analysis_service(result: rejected) do
        events = capture_pilot_usage_events do
          messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
            FieldPhotoAnalysisJob.perform_now(**job_args.merge(
              question: "qué marca es",
              expected_episode_id: owner
            ))
          end
        end
      end

      photo = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha)
      kept = @session.reload.active_episode
      context = Rag::ActivePhotoContext.resolve(
        episode: Rag::ActiveEpisode.parse(kept), viewer_account: accounts(:legacy)
      )
      built = SessionContextBuilder.build(@session, active_photo_context: context)
      acceptance = events.find { |event| event["event"] == "photo_observation_acceptance" }

      assert_equal 0, service_calls
      assert_nil photo.visual_observation
      assert_equal "photo_analyzed", messages.last["status"]
      assert_includes messages.last["summary"], "Lectura pagada SECRET-MFR"
      assert_equal "invalid", acceptance["result"]
      assert_equal "invalid_enum", acceptance["outcome_reason"]
      assert_equal photo.id, acceptance["field_photo_id"]
      assert_not acceptance.key?("manufacturer")
      assert_not acceptance.key?("visible_codes")
      assert kept["facts"].to_h.values.none? { |fact| fact["source"] == "photo" }
      assert_empty Array(kept["conflicts"])
      assert_equal "manufacturer", kept.dig("pending_question", "type")
      assert_equal "manufacturer", kept.dig("pending_fact", "subject")
      assert @session.conversation_history.none? { |message| message["content"].to_s.include?("[FOTO]") }
      assert @session.conversation_history.none? { |message| message["content"].to_s.include?("SECRET-MFR") }
      assert_equal "invalid", context.status
      assert_not_includes built, "SECRET-MFR"
      assert_not_includes built, "CODE-NEW"
    end
  ensure
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    set_photo_question_flag(nil)
  end

  test "an invalid new photo moves the pointer without keeping the previous photo active" do
    set_photo_question_flag("true")
    service_calls = 0
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| service_calls += 1 }
    first = analysis_result.merge(relevance_to_goal: "relevant", target_visible: true)
    first[:parsed] = first[:parsed].merge("manufacturer" => "KONE", "model" => "M1")

    with_episode_flag("true") do
      owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:job-test")
      with_analysis_service(result: first) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(expected_episode_id: owner))
      end
      episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
      episode.pending_question = { "type" => "controller", "carry" => [ "Q2" ] }
      episode.pending_fact = { "subject" => "controller", "correlation_id" => "seed" }
      @session.update!(active_episode: episode.to_h)
      foto_lines = @session.conversation_history.count { |message| message["content"].to_s.start_with?("[FOTO]") }

      messages = nil
      with_analysis_service(result: rejected_result) do
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(
            image_token: pending_token,
            image_sha256: Digest::SHA256.hexdigest("jpeg-2"),
            question: "qué marca es esta placa",
            expected_episode_id: owner
          ))
        end
      end

      kept = @session.reload.active_episode
      new_photo = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: Digest::SHA256.hexdigest("jpeg-2"))
      context = Rag::ActivePhotoContext.resolve(
        episode: Rag::ActiveEpisode.parse(kept), viewer_account: accounts(:legacy)
      )
      perception = Rag::TurnPerception::Result.new(
        valid: true, move: "follow_up", observations: [], pending_resolution: nil, clarification_target: nil,
        identities: [], ambiguities: [], field_rejections: [], catalog_disagreements: [], invalid_reason: nil
      )
      decision = Rag::RoutePolicy.call(
        previous: Rag::ActiveEpisode.parse(kept), perception: perception, focus_count: 0, relevant_photo: context.relevant?
      )
      query = Rag::QueryComposer.call(
        state: Rag::ActiveEpisode.parse(kept), turn: "¿Qué reviso ahora?", perception: perception, decision: decision,
        active_photo_context: context
      )
      built = SessionContextBuilder.build(@session, active_photo_context: context)

      assert_equal 0, service_calls
      assert_nil new_photo.visual_observation
      assert_equal new_photo.id, kept.dig("active_photo", "field_photo_id")
      assert_equal "KONE", kept.dig("facts", "manufacturer", "value")
      assert_equal "M1", kept.dig("facts", "model", "value")
      assert_empty Array(kept["conflicts"])
      assert_equal "controller", kept.dig("pending_question", "type")
      assert_equal [ "Q2" ], kept.dig("pending_question", "carry")
      assert_equal "invalid", context.status
      assert_equal foto_lines, @session.conversation_history.count { |message| message["content"].to_s.start_with?("[FOTO]") }
      assert_includes messages.last["summary"], "Lectura pagada SECRET-MFR"
      assert_not_includes built, "SECRET-MFR"
      assert_not_includes built, "CODE-NEW"
      assert_not_includes query.to_s, "SECRET-MFR"
      assert_not_includes query.to_s, "CODE-NEW"
    end
  ensure
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    set_photo_question_flag(nil)
  end

  test "an invalid reread stays display-only and does not reuse the stored observation" do
    photo = create_observed_photo(manufacturer: "KONE")
    set_photo_question_flag("true")
    service_calls = 0
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| service_calls += 1 }
    FieldPhotoPendingImageStore.delete(token: @token, account_id: accounts(:legacy).id)

    with_episode_flag("true") do
      owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:job-test")
      @session.record_photo_observation!(
        photo_value: {
          manufacturer: "KONE", model_visible: "MX-A", relevance_to_goal: "relevant", target_visible: true
        },
        field_photo_id: photo.id, sha256: photo.sha256, correlation_id: "photo:stored",
        expected_episode_id: owner
      )
      @session.update!(conversation_history: @session.conversation_history + [ {
        "role" => "assistant",
        "content" => "[FOTO] Componente: resortes | Fabricante: KONE",
        "ts" => Time.current.iso8601,
        "correlation_id" => "photo:stored"
      } ])
      before = @session.conversation_history.size

      messages = nil
      with_analysis_service(result: rejected_result.merge(analysis: "Lectura nueva B")) do
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(
            image_token: nil,
            field_photo_id: photo.id,
            image_sha256: photo.sha256,
            continuity: "reread",
            question: "volvé a leer la placa",
            expected_episode_id: owner
          ))
        end
      end

      kept = @session.reload.active_episode
      assert_equal 0, service_calls
      assert_equal "KONE", photo.reload.visual_observation["manufacturer"]
      assert_equal [ "R1" ], photo.visual_observation["visible_text"]
      assert_equal "KONE", kept.dig("facts", "manufacturer", "value")
      assert_equal "MX-A", kept.dig("facts", "model", "value")
      assert_equal before, @session.conversation_history.size
      assert_equal "photo_analyzed", messages.last["status"]
      assert_includes messages.last["summary"], "Lectura nueva B"
      assert messages.none? { |message| message["status"] == "photo_question_answered" }
      assert_not_includes messages.to_json, "provenance_segments"
    end
  ensure
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    set_photo_question_flag(nil)
  end

  test "a valid reread replaces the observation and downstream uses only the new reading" do
    photo = create_observed_photo(manufacturer: "OTIS")
    FieldPhotoPendingImageStore.delete(token: @token, account_id: accounts(:legacy).id)
    replacement = complete_observation_result.merge(
      analysis: "Lectura nueva KONE",
      compact_context: "[FOTO] RAW OTIS-OLD",
      relevance_to_goal: "relevant",
      target_visible: true
    )
    replacement[:parsed] = replacement[:parsed].merge("manufacturer" => "KONE", "model" => "MX20")
    captured = nil
    queried = nil
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) do |**kwargs|
      captured = kwargs
      original_new.call(**kwargs)
    end
    orig_query = BedrockRagService.instance_method(:query)
    BedrockRagService.define_method(:query) do |_question, **kwargs|
      queried = kwargs
      { answer: "En la foto: se observa KONE.", citations: [], session_id: nil }
    end
    set_photo_question_flag("true")

    with_episode_flag("true") do
      owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:job-test")
      with_analysis_service(result: replacement) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(
          image_token: nil,
          field_photo_id: photo.id,
          image_sha256: photo.sha256,
          continuity: "reread",
          question: "qué marca es",
          expected_episode_id: owner
        ))
      end

      stored = photo.reload.visual_observation
      kept = @session.reload.active_episode
      assert_equal "KONE", stored["manufacturer"]
      assert_equal "MX20", stored["model"]
      assert_equal "KONE", kept.dig("facts", "manufacturer", "value")
      assert_equal "MX20", kept.dig("facts", "model", "value")
      assert_equal "photo", kept.dig("facts", "manufacturer", "source")
      assert_equal accepted_compact_context(replacement), @session.conversation_history.first["content"]
      assert_not_includes @session.conversation_history.pluck("content"), replacement[:compact_context]
      assert_equal "KONE", captured[:evidence_value][:manufacturer]
      assert_equal "MX20", captured[:evidence_value][:model_visible]
      assert_equal "KONE", captured[:accepted_observation]["manufacturer"]
      assert_equal "MX20", captured[:accepted_observation]["model"]
      assert_equal stored["manufacturer"], captured[:evidence_value][:manufacturer]
      assert_not_includes captured[:evidence_value][:compact_context], "OTIS-OLD"
      assert_includes queried[:session_context], "Manufacturer: KONE"
      assert_includes queried[:session_context], "Model: MX20"
      assert_not_includes queried[:session_context], "OTIS"
    end
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    set_photo_question_flag(nil)
  end

  test "a stale writer keeps the accepted observation and skips history retrieval and generation" do
    set_photo_question_flag("true")
    service_calls = 0
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| service_calls += 1 }
    reading = complete_observation_result.merge(
      analysis: "Lectura tardía",
      relevance_to_goal: "relevant",
      target_visible: true
    )
    reading[:parsed] = reading[:parsed].merge("manufacturer" => "SCHINDLER", "model" => "S3300")

    with_episode_flag("true") do
      @session.record_user_turn!("Cómo se ajustan los resortes?", user_id: users(:one).id, correlation_id: "query:1")
      owner = @session.live_episode_id
      @session.record_user_turn!(
        "Ahora estoy revisando un KONE que no nivela en planta 3",
        user_id: users(:one).id, correlation_id: "query:2"
      )
      later = @session.live_episode_id
      assert_not_equal owner, later

      messages = nil
      with_analysis_service(result: reading) do
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(
            question: "qué marca es",
            expected_episode_id: owner
          ))
        end
      end

      photo = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha)
      kept = @session.reload.active_episode
      assert_equal 0, service_calls
      assert_equal "SCHINDLER", photo.visual_observation["manufacturer"]
      assert_equal later, kept["episode_id"]
      assert_nil kept["active_photo"]
      assert_nil kept.dig("facts", "model")
      assert_equal "KONE", kept.dig("facts", "manufacturer", "value")
      assert_equal "user", kept.dig("facts", "manufacturer", "source")
      assert_not_includes @session.conversation_history.pluck("content"), accepted_compact_context(reading)
      assert_equal "photo_analyzed", messages.last["status"]
      assert_includes messages.last["summary"], "Lectura tardía"
    end
  ensure
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    set_photo_question_flag(nil)
  end

  test "a case change after the photo write stops the photo-question path" do
    set_photo_question_flag("true")
    service_calls = 0
    original_write = ConversationSession.instance_method(:record_photo_observation!)
    ConversationSession.define_method(:record_photo_observation!) do |**kwargs|
      state = original_write.bind_call(self, **kwargs)
      start_new_case!(reason: "technician_new_case", correlation_id: "case:b") if state == :applied
      state
    end
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| service_calls += 1 }

    with_episode_flag("true") do
      owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:job-test")
      messages = nil
      with_analysis_service(result: analysis_result) do
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(
            question: "Cómo se ajustan los resortes de la fijación de cables?",
            expected_episode_id: owner
          ))
        end
      end

      photo = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha)
      episode = @session.reload.active_episode
      assert photo.visual_observation.present?
      assert_equal "Panel", photo.visual_observation["canonical_component"]
      assert_not_equal owner, episode["episode_id"]
      assert_nil episode["active_photo"]
      assert episode["facts"].to_h.values.none? { |fact| fact["source"] == "photo" }
      assert @session.conversation_history.none? { |message| message["content"].to_s.include?("[FOTO]") }
      assert_equal 0, service_calls
      assert_equal "photo_analyzed", messages.last["status"]
      assert_equal "Visible analysis", messages.last["summary"]
      assert messages.none? { |message| message["status"] == "photo_question_answered" }
    end
  ensure
    ConversationSession.define_method(:record_photo_observation!, original_write) if original_write
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    set_photo_question_flag(nil)
  end

  test "not_recording still answers a photo question from the accepted observation" do
    set_photo_question_flag("true")
    service_calls = 0
    seen = nil
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) do |**kwargs|
      service_calls += 1
      seen = kwargs
      service = Object.new
      service.define_singleton_method(:call) do
        { answer: "Respuesta aceptada", citations: [], provenance_segments: [], generation_mode: "test" }
      end
      service
    end

    messages = nil
    with_episode_flag(nil) do
      with_analysis_service(result: analysis_result) do
        messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
          FieldPhotoAnalysisJob.perform_now(**job_args.merge(
            question: "Cómo se ajustan los resortes de la fijación de cables?"
          ))
        end
      end
    end

    photo = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha)
    assert_equal 1, service_calls
    assert_equal "Panel", seen[:accepted_observation]["canonical_component"]
    assert_equal photo.visual_observation["manufacturer"], seen[:accepted_observation]["manufacturer"]
    assert_equal "UNKNOWN", seen[:evidence_value][:manufacturer]
    assert_equal [ "photo_question_answered" ], messages.pluck("status")
    assert_equal "Respuesta aceptada", messages.last["answer"]
    assert @session.reload.conversation_history.any? { |message| message["content"].to_s.start_with?("[FOTO]") }
  ensure
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
    set_photo_question_flag(nil)
  end

  test "a case change after the photo-history snapshot does not enter generation" do
    set_photo_question_flag("true")
    captured = {}
    original_execute = Rag::PhotoQuestionAnswerService.instance_method(:execute_rag_query)
    Rag::PhotoQuestionAnswerService.define_method(:execute_rag_query) do |_question, **kwargs|
      captured.replace(kwargs)
      RagQueryConcern::RagResult.new(
        true, "Respuesta congelada de la puerta", [], [], [], nil, nil, nil, nil, nil,
        nil, nil, nil, "test"
      )
    end
    original_context = ConversationSession.instance_method(:record_photo_assistant_context!)
    ConversationSession.define_method(:record_photo_assistant_context!) do |content, **kwargs|
      turn = original_context.bind_call(self, content, **kwargs)
      if turn.status == :applied
        start_new_case!(reason: "technician_new_case", correlation_id: "case:b")
        episode = Rag::ActiveEpisode.parse(reload.active_episode)
        episode.assign_goal!("no nivela", correlation_id: "case:b")
        episode.write_fact!(
          "manufacturer", status: "known", value: "OTIS", source: "user",
          correlation_id: "case:b", at: Time.current.iso8601
        )
        update!(active_episode: episode.to_h)
      end
      turn
    end

    with_episode_flag("true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
          owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:job-test")
          episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
          episode.assign_goal!("puerta no cierra", correlation_id: "photo:job-test")
          episode.write_fact!(
            "manufacturer", status: "known", value: "KONE", source: "user",
            correlation_id: "photo:job-test", at: Time.current.iso8601
          )
          @session.update!(active_episode: episode.to_h)
          reading = analysis_result.merge(
            analysis: "Lectura KONE", relevance_to_goal: "relevant", target_visible: true
          )
          reading[:parsed] = reading[:parsed].merge(
            "canonical_component" => "puerta",
            "manufacturer" => "KONE",
            "model" => "UNKNOWN",
            "subsystem" => "DOOR_OPERATOR",
            "condition" => "GOOD"
          )

          messages = nil
          with_analysis_service(result: reading) do
            messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
              FieldPhotoAnalysisJob.perform_now(**job_args.merge(
                question: "Cómo se ajustan los resortes de la fijación de cables?",
                expected_episode_id: owner
              ))
            end
          end

          context = captured[:session_context].to_s
          composed = captured[:retrieval_question].to_s
          kept = @session.reload.active_episode
          history = @session.conversation_history.pluck("content")
          assert_includes context, "puerta no cierra"
          assert_includes context, "KONE"
          assert_includes context, "Photo Evidence"
          assert_not_includes context, "OTIS"
          assert_not_includes context, "no nivela"
          assert_includes composed, "puerta no cierra"
          assert_includes composed, "KONE"
          assert_not_includes composed, "OTIS"
          assert_not_includes composed, "no nivela"
          assert_nil captured[:conv_session]
          assert_not_equal owner, kept["episode_id"]
          assert_equal "no nivela", kept.dig("goal", "text")
          assert_equal "OTIS", kept.dig("facts", "manufacturer", "value")
          assert_equal "user", kept.dig("facts", "manufacturer", "source")
          assert_nil kept["active_photo"]
          assert kept["facts"].to_h.values.none? { |fact| fact["source"] == "photo" }
          assert history.any? { |line| line.to_s.include?("[FOTO]") }
          assert_not_includes history, messages.last["answer"]
          assert_equal "photo_question_answered", messages.last["status"]
        end
      end
    end
  ensure
    ConversationSession.define_method(:record_photo_assistant_context!, original_context) if original_context
    Rag::PhotoQuestionAnswerService.define_method(:execute_rag_query, original_execute) if original_execute
    set_photo_question_flag(nil)
  end

  private

  def accepted_compact_context(result)
    observation = FieldPhotoObservation.from_analysis(
      parsed: result.fetch(:parsed),
      model_id: result.fetch(:model),
      target_visible: result[:target_visible],
      relevance_to_goal: result[:relevance_to_goal]
    )
    FieldPhotoObservation.reading_value(observation).fetch(:compact_context)
  end

  def captionless_follow_up
    episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
    context = Rag::ActivePhotoContext.resolve(episode: episode, viewer_account: accounts(:legacy))
    perception = Rag::TurnPerception::Result.new(
      valid: true, move: "follow_up", observations: [], pending_resolution: nil, clarification_target: nil,
      identities: [], ambiguities: [], field_rejections: [], catalog_disagreements: [], invalid_reason: nil
    )
    decision = Rag::RoutePolicy.call(
      previous: episode, perception: perception, focus_count: 0, relevant_photo: context.relevant?
    )
    query = Rag::QueryComposer.call(
      state: episode, turn: "¿Qué reviso ahora?", perception: perception, decision: decision,
      active_photo_context: context
    )
    generation = SessionContextBuilder.build(@session, active_photo_context: context)
    [ context, query, generation ]
  end

  def display_vision_json
    vision_json(
      "canonical_component" => "display de puerta",
      "manufacturer" => "NICE",
      "model" => "NICE3000",
      "subsystem" => "DOOR_OPERATOR",
      "condition" => "DEGRADED",
      "visible_text" => [ "E51" ],
      "target_visible" => true,
      "relevance_to_goal" => "relevant",
      "summary" => "Se ve un display."
    )
  end

  test "legacy nil photo reuse keeps the stored relevance, skips vision, and promotes identity" do
    photo = create_orona_photo(relevance: nil)
    calls = 0

    with_leveling_episode do |owner|
      with_analysis_service(on_call: -> { calls += 1 }) do
        FieldPhotoAnalysisJob.perform_now(**reuse_job_args(photo, owner, LEGACY_PHOTO_FOLLOW_UP))
      end
    end

    assert_equal 0, calls
    assert_nil photo.reload.visual_observation["relevance_to_goal"]
    assert_equal "Orona", photo.visual_observation["manufacturer"]
    assert_equal "PBCM-V3", photo.visual_observation["model"]
    episode = @session.reload.active_episode
    assert_equal photo.id, episode.dig("active_photo", "field_photo_id")
    assert_equal "Orona", episode.dig("facts", "manufacturer", "value")
    assert_equal "photo", episode.dig("facts", "manufacturer", "source")
    assert_equal "PBCM-V3", episode.dig("facts", "model", "value")
    assert_equal "photo", episode.dig("facts", "model", "source")
    assert_equal "no nivela en planta 3", episode.dig("goal", "text")
  end

  test "legacy photo reuse carries accepted equipment identity into retrieval" do
    n0_contract!("N2")
    photo = create_orona_photo(relevance: nil)
    calls = 0
    captured = {}

    with_leveling_episode do |owner|
      with_analysis_service(on_call: -> { calls += 1 }) do
        capture_photo_retrieval(captured) do
          FieldPhotoAnalysisJob.perform_now(**reuse_job_args(photo, owner, LEGACY_PHOTO_FOLLOW_UP))
        end
      end
    end

    assert_equal 0, calls
    assert_nil photo.reload.visual_observation["relevance_to_goal"]
    episode = @session.reload.active_episode
    assert_equal "Orona", episode.dig("facts", "manufacturer", "value")
    assert_equal "photo", episode.dig("facts", "manufacturer", "source")
    assert_equal "PBCM-V3", episode.dig("facts", "model", "value")
    assert_equal "photo", episode.dig("facts", "model", "source")
    assert_ephemeral_orona_identity(captured)
    assert_retrieval_question_carries_leveling_identity(captured)
  end

  test "same-turn photo question composes retrieval after accepted visual identity" do
    n0_contract!("N2")
    calls = 0
    interpreter_calls = { n: 0 }
    captured = {}

    with_leveling_episode do |owner|
      counting_turn_interpreter(interpreter_calls) do
        with_analysis_service(result: orona_plate_result(relevance: "relevant"), on_call: -> { calls += 1 }) do
          capture_photo_retrieval(captured) do
            FieldPhotoAnalysisJob.perform_now(**job_args.merge(
              question: SAME_TURN_PHOTO_QUESTION,
              expected_episode_id: owner,
              correlation_id: "photo:n0-same-turn"
            ))
          end
        end
      end
    end

    photo = FieldPhoto.find_by!(account_id: accounts(:legacy).id, sha256: @sha)
    assert_equal 1, calls
    assert_equal 0, interpreter_calls[:n]
    assert photo.visual_observation.present?
    assert_equal "relevant", photo.visual_observation["relevance_to_goal"]
    assert_equal "Orona", photo.visual_observation["manufacturer"]
    assert_equal "PBCM-V3", photo.visual_observation["model"]
    assert_includes captured[:question].to_s, SAME_TURN_PHOTO_QUESTION
    assert_retrieval_question_carries_leveling_identity(captured)
    assert_ephemeral_orona_identity(captured)
  end

  test "unrelated accepted photo does not constrain retrieval identity" do
    photo = create_orona_photo(relevance: "unrelated")
    calls = 0
    captured = {}

    isolate_env("DOCUMENT_IDENTITY_SCOPE_ENABLED", "true") do
      with_leveling_episode do |owner|
        with_analysis_service(on_call: -> { calls += 1 }) do
          capture_photo_retrieval(captured) do
            FieldPhotoAnalysisJob.perform_now(**reuse_job_args(photo, owner, "según la foto"))
          end
        end
      end
    end

    assert_equal 0, calls
    assert_equal "unrelated", photo.reload.visual_observation["relevance_to_goal"]
    episode = @session.reload.active_episode
    assert_nil episode.dig("facts", "manufacturer")
    assert_nil episode.dig("facts", "model")
    assert_nil identity_manufacturer(captured.dig(:service, :equipment_identity))
    assert_empty identity_needles(captured.dig(:service, :equipment_identity))
    assert_equal false, Rag::DocumentIdentityScope.applicable?(captured[:episode])
    assert_not_includes captured[:question].to_s, "Orona"
    assert_not_includes captured[:question].to_s, "PBCM-V3"
  end

  test "reused photo identity conflicts with a stated manufacturer and does not replace it" do
    photo = create_orona_photo(relevance: nil)

    with_leveling_episode do |owner|
      episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
      episode.write_fact!(
        "manufacturer", status: "known", value: "KONE", source: "user",
        correlation_id: "query:kone", at: Time.current.iso8601
      )
      @session.update!(active_episode: episode.to_h)
      FieldPhotoAnalysisJob.perform_now(**reuse_job_args(photo, owner, LEGACY_PHOTO_FOLLOW_UP))
    end

    episode = @session.reload.active_episode
    assert_equal "KONE", episode.dig("facts", "manufacturer", "value")
    assert_equal "user", episode.dig("facts", "manufacturer", "source")
    conflict = Array(episode["conflicts"]).find { |row| row["fact"] == "manufacturer" }
    assert_equal "KONE", conflict["user"]
    assert_equal "Orona", conflict["photo"]
    assert_equal "PBCM-V3", episode.dig("facts", "model", "value")
    assert_equal "photo", episode.dig("facts", "model", "source")
  end

  test "a late photo reuse does not promote identity onto the new episode" do
    photo = create_orona_photo(relevance: nil)
    service_calls = 0
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**_| service_calls += 1 }
    original_write = ConversationSession.instance_method(:record_photo_observation!)
    ConversationSession.define_method(:record_photo_observation!) do |**kwargs|
      state = original_write.bind_call(self, **kwargs)
      if state == :applied
        start_new_case!(reason: "technician_new_case", correlation_id: "case:b")
        opened = Rag::ActiveEpisode.parse(reload.active_episode)
        opened.assign_goal!("el variador no arranca", correlation_id: "case:b")
        update!(active_episode: opened.to_h)
      end
      state
    end
    owner_id = nil
    events = []

    with_leveling_episode do |owner|
      owner_id = owner
      episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
      episode.active_photo = {
        "field_photo_id" => photo.id,
        "sha256" => photo.sha256,
        "correlation_id" => "photo:a"
      }
      @session.update!(active_episode: episode.to_h)
      output = StringIO.new
      logger = ActiveSupport::Logger.new(output)
      Rails.logger.broadcast_to(logger)
      begin
        FieldPhotoAnalysisJob.perform_now(**reuse_job_args(photo, owner, LEGACY_PHOTO_FOLLOW_UP))
      ensure
        Rails.logger.stop_broadcasting_to(logger)
      end
      events = output.string.lines.filter_map do |line|
        start = line.index("{")
        next unless start

        parsed = JSON.parse(line[start..])
        parsed if parsed.is_a?(Hash) && parsed["event"].present?
      rescue JSON::ParserError
        nil
      end
    end

    kept = @session.reload.active_episode
    assert_not_equal owner_id, kept["episode_id"]
    assert_equal "el variador no arranca", kept.dig("goal", "text")
    assert_nil kept["active_photo"]
    assert_nil kept.dig("facts", "manufacturer")
    assert_nil kept.dig("facts", "model")
    assert kept["facts"].to_h.values.none? { |fact| fact.is_a?(Hash) && fact["source"] == "photo" }
    assert_not_includes @session.conversation_history.pluck("content").join("\n"), "Orona"
    assert_not_includes @session.conversation_history.pluck("content").join("\n"), "PBCM-V3"
    assert_equal 0, service_calls
    dropped = events.find { |event| event["event"] == "stale_case_write_dropped" && event["writer"] == "photo_assistant" }
    assert_equal true, dropped["dropped"]
    assert_equal owner_id, dropped["expected_episode_id"]
    assert_equal kept["episode_id"], dropped["current_episode_id"]
  ensure
    ConversationSession.define_method(:record_photo_observation!, original_write) if original_write
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
  end

  test "uncertain accepted photo constrains retrieval and promotes identity on reuse" do
    n0_contract!("N2")
    photo = create_orona_photo(relevance: "uncertain")
    captured = {}

    with_leveling_episode do |owner|
      capture_photo_retrieval(captured) do
        FieldPhotoAnalysisJob.perform_now(**reuse_job_args(photo, owner, "de la foto, qué reviso primero"))
      end
    end

    assert_equal "uncertain", photo.reload.visual_observation["relevance_to_goal"]
    episode = @session.reload.active_episode
    assert_equal "Orona", episode.dig("facts", "manufacturer", "value")
    assert_equal "photo", episode.dig("facts", "manufacturer", "source")
    assert_equal "PBCM-V3", episode.dig("facts", "model", "value")
    assert_equal "photo", episode.dig("facts", "model", "source")
    assert_equal photo.id, episode.dig("active_photo", "field_photo_id")
    assert_ephemeral_orona_identity(captured)
    assert_includes captured[:question].to_s, "no nivela en planta 3"
    assert_includes captured[:question].to_s, "Orona"
    assert_includes captured[:question].to_s, "PBCM-V3"
  end

  test "foreign manufacturer chunks are reference-only for known equipment" do
    n0_contract!("N3")
    probe = run_foreign_equipment_retrieval
    scope = probe[:scopes].last

    assert scope, "known Orona/PBCM-V3 identity must reach DocumentIdentityScope"
    values = scope_identity_values(scope[:identity])
    assert_includes values, "Orona"
    assert_includes values, "PBCM-V3"
    labels = Array(scope[:labels]).map(&:to_s)
    assert_equal 2, labels.size
    assert labels.all? { |label| label.start_with?("REFERENCE ONLY") }, labels.inspect
    assert labels.any? { |label| label.include?("Yida") }
    assert labels.any? { |label| label.include?("BLT") }
    assert labels.none? { |label| label.include?("THIS JOB") }
    Array(scope[:chunks]).each do |chunk|
      assert_not_includes chunk[:content].to_s, YIDA_PROCEDURE
      assert_not_includes chunk[:content].to_s, BLT_PROCEDURE
    end
    probe[:prompts].each do |prompt|
      assert_not_includes prompt, YIDA_PROCEDURE
      assert_not_includes prompt, BLT_PROCEDURE
    end
    assert_nil probe[:photo].reload.visual_observation["relevance_to_goal"]
  end

  test "known equipment photo retrieval does not fall open onto a foreign procedure" do
    n0_contract!("N4")
    probe = run_foreign_equipment_retrieval

    assert_equal 0, probe[:open_calls], "known equipment must not fall through to open retrieve_and_generate"
    assert_not_includes probe[:answer], YIDA_PROCEDURE
    assert_not_includes probe[:answer], BLT_PROCEDURE
  end

  test "no compatible photo continues the active problem as companion guidance" do
    vision_calls = 0
    interpreter_calls = { n: 0 }
    probe = nil
    counting_turn_interpreter(interpreter_calls) do
      with_analysis_service(on_call: -> { vision_calls += 1 }) do
        probe = run_foreign_equipment_retrieval
      end
    end

    prompt = probe[:prompts].find { |text| text.include?("# FIELD COMPANION") }
    assert prompt, "companion generation prompt missing"
    assert_includes prompt, "no nivela en planta 3"
    assert_includes prompt, "Orona"
    assert_includes prompt, "PBCM-V3"
    assert_includes prompt, "CONTROLLER_LOGIC"
    assert_includes prompt, "No compatible manufacturer manual was found."
    assert_not_includes prompt, YIDA_PROCEDURE
    assert_not_includes prompt, BLT_PROCEDURE
    assert_equal 0, probe[:open_calls]
    assert_equal 0, vision_calls
    assert_equal 0, interpreter_calls[:n]
    assert_includes probe[:answer], "Orona PBCM-V3"
    assert_includes probe[:answer], "pasada o corta"
    assert_includes probe[:answer], "planta 3"
    assert_not_includes probe[:answer], YIDA_PROCEDURE
    assert_not_includes probe[:answer], BLT_PROCEDURE
    assert_not_includes probe[:answer], "select a manual"
    bands = probe[:segments].pluck("band")
    assert_includes bands, "VISUAL_OBSERVATION"
    assert_includes bands, "DANEBO_GUIDANCE"
    assert_not_includes bands, "MANUAL_FACT"
    assert_equal [], probe[:citations]
    assert_nil probe[:photo].reload.visual_observation["relevance_to_goal"]
    episode = @session.reload.active_episode
    assert_equal "Orona", episode.dig("facts", "manufacturer", "value")
    assert_equal "photo", episode.dig("facts", "manufacturer", "source")
    assert_equal "PBCM-V3", episode.dig("facts", "model", "value")
    assert_equal "photo", episode.dig("facts", "model", "source")
    assert_equal "no nivela en planta 3", episode.dig("goal", "text")
  end

  test "uncertain accepted photo promotes identity and keeps a safe companion answer" do
    probe = run_foreign_equipment_retrieval(relevance: "uncertain")

    assert_equal "uncertain", probe[:photo].reload.visual_observation["relevance_to_goal"]
    episode = @session.reload.active_episode
    assert_equal "Orona", episode.dig("facts", "manufacturer", "value")
    assert_equal "photo", episode.dig("facts", "manufacturer", "source")
    assert_equal "PBCM-V3", episode.dig("facts", "model", "value")
    assert_equal "photo", episode.dig("facts", "model", "source")
    prompt = probe[:prompts].find { |text| text.include?("# FIELD COMPANION") }
    assert_includes prompt, "Orona"
    assert_includes prompt, "PBCM-V3"
    assert_not_includes prompt, YIDA_PROCEDURE
    assert_includes probe[:answer], "pasada o corta"
    assert_not_includes probe[:segments].pluck("band"), "MANUAL_FACT"
    assert_equal [], probe[:citations]
  end

  test "a known photo with a missing identity snapshot keeps the paid visual reading" do
    set_photo_question_flag("true")
    photo = create_orona_photo(relevance: "relevant")
    vision_calls = 0
    open_calls = 0
    orig_query = BedrockRagService.instance_method(:query)
    orig_capture = Rag::PhotoRetrievalSnapshot.method(:capture)
    BedrockRagService.define_method(:query) do |*|
      open_calls += 1
      { answer: YIDA_PROCEDURE, citations: [], session_id: nil }
    end
    Rag::PhotoRetrievalSnapshot.define_singleton_method(:capture) do |**kwargs|
      derived = orig_capture.call(**kwargs)
      Rag::PhotoRetrievalSnapshot::Result.new(
        equipment_identity: nil,
        retrieval_question: derived.retrieval_question
      )
    end

    with_analysis_service(result: orona_plate_result(relevance: "relevant"), on_call: -> { vision_calls += 1 }) do
      messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
        FieldPhotoAnalysisJob.perform_now(**job_args.merge(
          field_photo_id: photo.id,
          question: "no nivela en planta 3"
        ))
      end

      answer_message = messages.last
      assert_equal 1, vision_calls
      assert_equal 0, open_calls
      assert_equal "photo_question_answered", answer_message["status"]
      assert_equal I18n.t("rag.photo_question_unavailable", locale: :es), answer_message["answer"]
      assert_equal "Placa controladora Orona PBCM-V3", answer_message["visual_summary"]
      assert_not_includes answer_message["answer"], YIDA_PROCEDURE
      assert_equal [], answer_message["citations"]
    end
  ensure
    BedrockRagService.define_method(:query, orig_query) if orig_query
    Rag::PhotoRetrievalSnapshot.define_singleton_method(:capture) { |**kwargs| orig_capture.call(**kwargs) } if orig_capture
    set_photo_question_flag(nil)
  end

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

  def rejected_result
    analysis_result.merge(
      analysis: "Lectura pagada SECRET-MFR",
      compact_context: "[FOTO] RAW SECRET-MFR SECRET-MODEL CODE-NEW",
      canonical_name: "placa nueva",
      relevance_to_goal: "relevant",
      target_visible: true,
      parsed: analysis_result[:parsed].merge(
        "canonical_component" => "placa nueva",
        "manufacturer" => "SECRET-MFR",
        "model" => "SECRET-MODEL",
        "subsystem" => "ELEVATOR",
        "condition" => "GOOD",
        "visible_text" => [ "CODE-NEW" ]
      )
    )
  end

  def analysis_result
    {
      analysis: "Visible analysis",
      compact_context: "[FOTO] RAW Componente: Panel | Fabricante: UNKNOWN",
      canonical_name: "Panel",
      aliases: [ "P1" ],
      parsed: {
        "canonical_component" => "Panel",
        "manufacturer" => "UNKNOWN",
        "model" => "P1",
        "subsystem" => "UNKNOWN",
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

  def seed_pending!(type:, carry: nil)
    owner = @session.ensure_case_for_photo_submission!(correlation_id: "photo:pending")
    episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
    question = { "type" => type }
    question["carry"] = carry if carry
    episode.pending_question = question
    episode.pending_fact = { "subject" => type, "correlation_id" => "seed" }
    @session.update!(active_episode: episode.to_h)
    owner
  end

  def orona_vision_json
    vision_json(
      "canonical_component" => "placa controladora",
      "manufacturer" => "Orona",
      "model" => "PBCM-V3",
      "subsystem" => "CONTROLLER_LOGIC",
      "condition" => "GOOD",
      "visible_text" => [ "ORONA", "PBCM-V3" ],
      "summary" => "Se ve una placa controladora.",
      "relevance_to_goal" => "relevant",
      "target_visible" => true
    )
  end

  def with_leveling_episode
    with_episode_flag("true") do
      isolate_env("PHOTO_QUESTION_RAG_ENABLED", "true") do
        owner = @session.ensure_case_for_photo_submission!(correlation_id: "query:goal")
        episode = Rag::ActiveEpisode.parse(@session.reload.active_episode)
        episode.assign_goal!("no nivela en planta 3", correlation_id: "query:goal")
        @session.update!(active_episode: episode.to_h)
        yield owner
      end
    end
  end

  def reuse_job_args(photo, owner, question)
    job_args.merge(
      image_token: nil,
      field_photo_id: photo.id,
      image_sha256: photo.sha256,
      continuity: "reuse",
      question: question,
      expected_episode_id: owner,
      correlation_id: "photo:n0-reuse"
    )
  end

  def create_orona_photo(relevance:)
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: accounts(:legacy),
      sha256: sha,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{sha}/original.jpg",
      content_type: "image/jpeg",
      byte_size: 8
    )
    payload = FieldPhotoObservation.from_analysis(
      parsed: orona_plate_result(relevance: relevance)[:parsed],
      model_id: "claude-sonnet-5-5",
      target_visible: nil,
      relevance_to_goal: relevance
    )
    assert FieldPhotoObservation.persist!(photo, payload)
    photo.reload
  end

  def orona_plate_result(relevance:)
    analysis_result.merge(
      model: "claude-sonnet-5-5",
      canonical_name: "Placa controladora",
      analysis: "Placa controladora Orona PBCM-V3",
      compact_context: "[FOTO] Componente: Placa controladora | Fabricante: Orona | Modelo: PBCM-V3",
      relevance_to_goal: relevance,
      target_visible: nil,
      parsed: {
        "canonical_component" => "Placa controladora",
        "manufacturer" => "Orona",
        "model" => "PBCM-V3",
        "subsystem" => "CONTROLLER_LOGIC",
        "condition" => "GOOD",
        "visible_text" => [ "PBCM-V3" ],
        "relevance_to_goal" => relevance
      }
    )
  end

  def capture_photo_retrieval(captured)
    original_query = BedrockRagService.instance_method(:query)
    original_new = Rag::PhotoQuestionAnswerService.method(:new)
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured[:question] = question
      captured[:episode] = kwargs[:episode]
      { answer: "Sin procedimiento de otro fabricante.", citations: [], session_id: nil }
    end
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) do |**kwargs|
      captured[:service] = kwargs
      original_new.call(**kwargs)
    end
    yield
  ensure
    BedrockRagService.define_method(:query, original_query) if original_query
    Rag::PhotoQuestionAnswerService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
  end

  def counting_turn_interpreter(counter)
    original = Rag::TurnInterpreter.method(:call)
    Rag::TurnInterpreter.define_singleton_method(:call) do |**kwargs|
      counter[:n] += 1
      original.call(**kwargs)
    end
    yield
  ensure
    Rag::TurnInterpreter.define_singleton_method(:call) { |**kwargs| original.call(**kwargs) } if original
  end

  def assert_ephemeral_orona_identity(captured)
    identity = captured.dig(:service, :equipment_identity)
    assert_equal "Orona", identity_manufacturer(identity)
    assert_includes identity_needles(identity), "PBCM-V3"
  end

  def assert_retrieval_question_carries_leveling_identity(captured)
    question = captured[:question].to_s
    composed = captured.dig(:service, :retrieval_question).to_s
    [ question, composed ].each do |text|
      assert_includes text, "no nivela en planta 3"
      assert_includes text, "Orona"
      assert_includes text, "PBCM-V3"
    end
  end

  def identity_manufacturer(identity)
    return if identity.nil?
    return identity.manufacturer if identity.respond_to?(:manufacturer)

    identity[:manufacturer] || identity["manufacturer"] if identity.respond_to?(:[])
  end

  def identity_needles(identity)
    return [] if identity.nil?

    raw = if identity.respond_to?(:needles)
      identity.needles
    elsif identity.respond_to?(:[])
      identity[:needles] || identity["needles"]
    end
    Array(raw).map(&:to_s)
  end

  def run_foreign_equipment_retrieval(relevance: nil)
    photo = create_orona_photo(relevance: relevance)
    probe = { open_calls: 0, prompts: [], scopes: [], answer: "", citations: [], segments: [], photo: photo }
    isolate_env("DOCUMENT_IDENTITY_SCOPE_ENABLED", "true") do
      with_leveling_episode do |owner|
        with_foreign_retrieval_probe(probe) do
          messages = capture_broadcasts(KbSyncBroadcaster.channel_for(accounts(:legacy).id)) do
            FieldPhotoAnalysisJob.perform_now(**reuse_job_args(photo, owner, LEGACY_PHOTO_FOLLOW_UP))
          end
          message = messages.last.to_h
          probe[:answer] = message["answer"].to_s
          probe[:citations] = Array(message["citations"])
          probe[:segments] = Array(message["provenance_segments"])
        end
      end
    end
    probe
  end

  def with_foreign_retrieval_probe(probe)
    original_apply = Rag::DocumentIdentityScope.method(:apply)
    original_new = BedrockRagService.method(:new)
    Rag::DocumentIdentityScope.define_singleton_method(:apply) do |chunks, identity, focus_uris: []|
      result = original_apply.call(chunks, identity, focus_uris: focus_uris)
      prompt = Rag::DocumentIdentityScope.generation_context(result.chunks, result.labels)
      probe[:scopes] << { identity: identity, labels: result.labels, chunks: result.chunks }
      probe[:prompts] << prompt
      result
    end
    yida = yida_procedure
    blt = blt_procedure
    citation = foreign_yida_citation
    BedrockRagService.define_singleton_method(:new) do |**kwargs|
      service = original_new.call(**kwargs, knowledge_base_id: "test-kb")
      service.define_singleton_method(:retrieve_chunks) do |*_args, **_kwargs|
        { chunks: [ yida, blt ], retrieval_trace: {} }
      end
      service.define_singleton_method(:fallback_retrieve) { |*, **| [] }
      service.define_singleton_method(:retrieve_and_generate_with_retry) do |_params|
        probe[:open_calls] += 1
        output = Struct.new(:text).new("#{YIDA_PROCEDURE} [1]")
        Struct.new(:output, :citations, :session_id).new(output, [ citation ], nil)
      end
      generator = Object.new
      generator.define_singleton_method(:query) do |prompt, **|
        probe[:prompts] << prompt
        <<~ANSWER.strip
          En la foto se identifica Orona PBCM-V3.
          No tengo un manual compatible para darte un procedimiento del fabricante.
          Para acotar la nivelación quiero separar si la cabina queda pasada o corta de nivel, o si no llega a hacer la parada.
          ¿Qué hace la cabina al llegar a planta 3?
        ANSWER
      end
      service.instance_variable_set(:@document_identity_generator, generator)
      service
    end
    yield
  ensure
    Rag::DocumentIdentityScope.define_singleton_method(:apply) { |*args, **kwargs| original_apply.call(*args, **kwargs) } if original_apply
    BedrockRagService.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) } if original_new
  end

  def scope_identity_values(identity)
    values = [ identity_manufacturer(identity), *identity_needles(identity) ]
    raw = identity.respond_to?(:to_h) ? identity.to_h : identity
    facts = raw.is_a?(Hash) ? (raw["facts"] || raw[:facts]) : nil
    if facts.is_a?(Hash)
      facts.each_value do |fact|
        value = fact.is_a?(Hash) ? (fact["value"] || fact[:value]) : fact
        values << value
      end
    end
    values.compact.map(&:to_s)
  end

  def foreign_yida_citation
    OpenStruct.new(
      generated_response_part: OpenStruct.new(
        text_response_part: OpenStruct.new(
          span: OpenStruct.new(start: 0, end: YIDA_PROCEDURE.length),
          text: YIDA_PROCEDURE
        )
      ),
      retrieved_references: [
        OpenStruct.new(
          content: OpenStruct.new(text: YIDA_PROCEDURE),
          location: OpenStruct.new(s3_location: OpenStruct.new(uri: "s3://bucket/chunks/yida.txt")),
          metadata: {
            "canonical_name" => "Fuji Yida Guía del Usuario Ascensor",
            "original_source_uri" => "s3://bucket/yida.pdf",
            "account_id" => accounts(:legacy).id.to_s,
            "page_number" => 97
          }
        )
      ]
    )
  end

  def yida_procedure
    {
      rank: 1,
      content: YIDA_PROCEDURE,
      metadata: {
        "account_id" => accounts(:legacy).id.to_s,
        "document_id" => "yida",
        "canonical_name" => "Fuji Yida Guía del Usuario Ascensor",
        "page_number" => 97
      },
      chunk_sha256: Digest::SHA256.hexdigest(YIDA_PROCEDURE)
    }
  end

  def blt_procedure
    {
      rank: 2,
      content: BLT_PROCEDURE,
      metadata: {
        "account_id" => accounts(:legacy).id.to_s,
        "document_id" => "blt",
        "canonical_name" => "Código de Avería BLT Ascensor",
        "page_number" => 4
      },
      chunk_sha256: Digest::SHA256.hexdigest(BLT_PROCEDURE)
    }
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
    parsed = complete_observation_result[:parsed].merge("manufacturer" => manufacturer)
    FieldPhotoObservation.persist!(
      photo,
      FieldPhotoObservation.from_analysis(
        parsed: parsed,
        model_id: "claude-sonnet-5-5",
        target_visible: parsed["target_visible"],
        relevance_to_goal: parsed["relevance_to_goal"]
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
