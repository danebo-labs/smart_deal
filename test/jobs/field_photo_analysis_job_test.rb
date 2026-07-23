# frozen_string_literal: true

require "test_helper"

class FieldPhotoAnalysisJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper
  parallelize(workers: 1)

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
  end

  teardown do
    Rails.cache = @previous_cache
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
      history = @session.reload.conversation_history.last
      assert_equal analysis_result[:compact_context], history["content"]
      assert_equal users(:one).id, history["user_id"]
      assert_equal "photo:job-test", history["correlation_id"]
      assert FieldPhotoDiagnosisCache.read(account_id: accounts(:legacy).id, sha256: @sha, locale: "es")
      assert_nil FieldPhotoPendingImageStore.take(token: @token, account_id: accounts(:legacy).id)
      assert_no_enqueued_jobs only: [ BedrockIngestionJob, SubmitManualBatchJob ]
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

  test "serialized job arguments contain no image bytes or base64" do
    FieldPhotoAnalysisJob.perform_later(**job_args)

    serialized = enqueued_jobs.last[:args].to_json
    assert_not_includes serialized, Base64.strict_encode64("jpeg")
    assert_not_includes serialized, '"data"'
    assert_not_includes serialized, '"binary"'
  end

  private

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
