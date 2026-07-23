# frozen_string_literal: true

class FieldPhotoAnalysisJob < ApplicationJob
  queue_as :default
  self.log_arguments = false

  # The temporary payload is deleted on every outcome, so retrying cannot safely
  # replay the visual call. Use the retry handler as a single, clean failure path.
  retry_on StandardError, wait: 2.seconds, attempts: 1 do |job, error|
    args = (job.arguments.first || {}).deep_symbolize_keys
    locale = args[:locale].presence || I18n.default_locale

    Rails.logger.error("FieldPhotoAnalysisJob failed: #{error.class}: #{error.message}")
    PilotUsageLog.log(
      "photo_failed",
      account_id: args[:account_id],
      user_id: args[:user_id],
      conversation_session_id: args[:conversation_session_id],
      correlation_id: args[:correlation_id],
      route: "visual_query",
      cache_status: "miss",
      result: "error",
      error_class: error.class.name,
      image_digest_prefix: args[:image_sha256].to_s.first(12)
    )
    KbSyncBroadcaster.failed(
      filenames: [ args[:filename].presence || "photo" ],
      account_id: args[:account_id],
      reason: "photo_analysis_error",
      message: I18n.with_locale(locale) { I18n.t("rag.photo_analysis_failed") },
      correlation_id: args[:correlation_id]
    )
  end

  def perform(image_token:, image_sha256:, filename:, content_type:, account_id:, user_id: nil,
              conversation_session_id: nil, locale: nil, correlation_id: nil)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    locale = locale.to_s.presence || I18n.default_locale.to_s
    correlation_id ||= "photo:#{SecureRandom.uuid}"
    session = conversation_session_id ? ConversationSession.find_by(id: conversation_session_id) : nil
    if session && account_id && session.account_id != account_id
      raise ArgumentError, "ConversationSession #{session.id} is not owned by account #{account_id}"
    end

    cached = FieldPhotoDiagnosisCache.read(
      account_id: account_id,
      sha256: image_sha256,
      locale: locale
    )
    return deliver_cached(
      cached,
      session: session,
      filename: filename,
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      image_sha256: image_sha256,
      delivery_latency_ms: elapsed_ms(started_at)
    ) if cached

    image = FieldPhotoPendingImageStore.take(token: image_token, account_id: account_id)
    unless image
      broadcast_expired(
        filename: filename,
        locale: locale,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        image_sha256: image_sha256
      )
      return
    end

    PilotUsageLog.log(
      "photo_cache_miss",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      route: "visual_query",
      cache_status: "miss",
      result: "processing",
      image_digest_prefix: image_sha256.to_s.first(12)
    )

    result = FieldPhotoAnalysisService.new(
      binary: image.fetch(:binary),
      content_type: image[:content_type].presence || content_type,
      filename: image[:filename].presence || filename,
      locale: locale,
      account_id: account_id,
      user_id: user_id,
      conv_session_id: conversation_session_id,
      correlation_id: correlation_id
    ).call

    cache_value = diagnosis_cache_value(result)
    FieldPhotoDiagnosisCache.write(
      account_id: account_id,
      sha256: image_sha256,
      locale: locale,
      value: cache_value
    )

    deliver(
      cache_value,
      session: session,
      filename: filename,
      account_id: account_id,
      user_id: user_id,
      correlation_id: correlation_id
    )
    PilotUsageLog.log(
      "photo_completed",
      **usage_fields(
        cache_value,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        cache_status: "miss",
        image_sha256: image_sha256
      )
    )
  ensure
    FieldPhotoPendingImageStore.delete(token: image_token, account_id: account_id)
  end

  private

  def deliver_cached(cached, session:, filename:, account_id:, user_id:,
                     conversation_session_id:, correlation_id:, image_sha256:,
                     delivery_latency_ms:)
    deliver(
      cached,
      session: session,
      filename: filename,
      account_id: account_id,
      user_id: user_id,
      correlation_id: correlation_id
    )
    fields = usage_fields(
      cached,
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      cache_status: "hit",
      image_sha256: image_sha256
    ).merge(
      latency_ms: delivery_latency_ms,
      original_latency_ms: cached[:latency_ms]
    )
    PilotUsageLog.log("photo_cache_hit", **fields.merge(cost: 0))
    PilotUsageLog.log(
      "visual_llm_call_avoided",
      **fields.merge(cost: 0, estimated_cost_avoided: cached[:original_cost])
    )
    PilotUsageLog.log("photo_completed", **fields.merge(cost: 0))
  end

  def deliver(value, session:, filename:, account_id:, user_id:, correlation_id:)
    session&.add_to_history(
      "assistant",
      value.fetch(:compact_context),
      user_id: user_id,
      correlation_id: correlation_id
    )
    KbSyncBroadcaster.photo_analyzed(
      filenames: [ filename ],
      analysis: value.fetch(:analysis),
      canonical_name: value[:canonical_name],
      aliases: value[:aliases],
      account_id: account_id,
      correlation_id: correlation_id
    )
  end

  def diagnosis_cache_value(result)
    usage = result.fetch(:usage).to_h.deep_symbolize_keys
    model_id = result.fetch(:model).to_s
    model_id = "#{model_id}-direct" unless model_id.end_with?("-direct", "-batch")
    input_tokens = usage[:input_tokens].to_i
    output_tokens = usage[:output_tokens].to_i
    cost = BedrockQuery.new(
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens
    ).cost
    parsed = result[:parsed].to_h

    {
      analysis: result.fetch(:analysis),
      compact_context: result.fetch(:compact_context),
      canonical_name: result[:canonical_name],
      aliases: Array(result[:aliases]),
      manufacturer: parsed["manufacturer"],
      model_visible: parsed["model"],
      condition: parsed["condition"],
      visible_codes: Array(parsed["visible_text"]).first(8),
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      original_cost: cost,
      latency_ms: result[:latency_ms],
      created_at: Time.current.iso8601,
      contract_version: FieldPhotoPrompt::CONTRACT_VERSION
    }
  end

  def usage_fields(value, account_id:, user_id:, conversation_session_id:, correlation_id:,
                   cache_status:, image_sha256:)
    {
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      route: "visual_query",
      model: value[:model_id],
      latency_ms: value[:latency_ms],
      input_tokens: value[:input_tokens],
      output_tokens: value[:output_tokens],
      cost: value[:original_cost],
      cache_status: cache_status,
      result: "ok",
      image_digest_prefix: image_sha256.to_s.first(12),
      canonical_name: value[:canonical_name],
      manufacturer: value[:manufacturer],
      model_visible: value[:model_visible],
      condition: value[:condition],
      visible_codes: value[:visible_codes]
    }
  end

  def broadcast_expired(filename:, locale:, account_id:, user_id:, conversation_session_id:,
                        correlation_id:, image_sha256:)
    PilotUsageLog.log(
      "photo_failed",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      route: "visual_query",
      cache_status: "miss",
      result: "expired",
      error_class: "PhotoUploadExpired",
      image_digest_prefix: image_sha256.to_s.first(12)
    )
    KbSyncBroadcaster.failed(
      filenames: [ filename ],
      account_id: account_id,
      reason: "photo_upload_expired",
      message: I18n.with_locale(locale) { I18n.t("rag.photo_upload_expired") },
      correlation_id: correlation_id
    )
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
