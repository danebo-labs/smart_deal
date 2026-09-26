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
