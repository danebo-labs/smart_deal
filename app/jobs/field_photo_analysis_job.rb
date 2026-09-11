# frozen_string_literal: true

require "digest"

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
    # self here is the job CLASS, not an instance (retry_on's exhausted-attempts
    # branch yields the user block directly, unlike instance_exec elsewhere in
    # this file) — call PilotUsageLog directly rather than the private
    # emit_interaction_completed instance helper used below.
    PilotUsageLog.log(
      "interaction_completed",
      account_id: args[:account_id],
      user_id: args[:user_id],
      conversation_session_id: args[:conversation_session_id],
      correlation_id: args[:correlation_id],
      outcome: "failed",
      stage: "error",
      error_class: error.class.name,
      route: "visual_query"
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
              conversation_session_id: nil, locale: nil, correlation_id: nil, field_photo_id: nil, question: nil)
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
    if cached
      if field_photo_id.blank? && image_token.present?
        pending = FieldPhotoPendingImageStore.take(token: image_token, account_id: account_id)
        field_photo_id = persist_field_photo(
          pending, account_id: account_id, sha256: image_sha256, filename: filename,
          content_type: content_type, user_id: user_id, conversation_session_id: conversation_session_id
        )
      end
      return deliver_cached(
        cached,
        session: session,
        filename: filename,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        image_sha256: image_sha256,
        field_photo_id: field_photo_id,
        delivery_latency_ms: elapsed_ms(started_at),
        locale: locale,
        question: question
      )
    end

    image = FieldPhotoPendingImageStore.take(token: image_token, account_id: account_id)
    rehydrated = false
    if image.nil? && field_photo_id.present? && account_id
      photo = FieldPhoto.where(account_id: account_id).find_by(id: field_photo_id)
      binary = photo && FieldPhotoStore.fetch_binary(photo)
      if binary.present?
        image = {
          binary: binary, content_type: photo.content_type, filename: filename,
          thumbnail_binary: photo.thumbnail_data, thumbnail_content_type: photo.thumbnail_content_type,
          thumbnail_width: photo.thumbnail_width, thumbnail_height: photo.thumbnail_height
        }
        rehydrated = true
      end
    end

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

    if rehydrated
      PilotUsageLog.log(
        "photo_reuse",
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        route: "visual_query",
        result: "rehydrated",
        image_digest_prefix: image_sha256.to_s.first(12)
      )
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

    if field_photo_id.blank?
      field_photo_id = persist_field_photo(
        image, account_id: account_id, sha256: image_sha256, filename: filename,
        content_type: content_type, user_id: user_id, conversation_session_id: conversation_session_id
      )
    end

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
      correlation_id: correlation_id,
      field_photo_id: field_photo_id,
      locale: locale,
      question: question
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
    emit_interaction_completed(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      outcome: photo_outcome(cache_value[:analysis]),
      latency_ms: elapsed_ms(started_at)
    )
  ensure
    FieldPhotoPendingImageStore.delete(token: image_token, account_id: account_id)
  end

  private

  def deliver_cached(cached, session:, filename:, account_id:, user_id:,
                     conversation_session_id:, correlation_id:, image_sha256:,
                     delivery_latency_ms:, field_photo_id: nil, locale: nil, question: nil)
    deliver(
      cached,
      session: session,
      filename: filename,
      account_id: account_id,
      user_id: user_id,
      correlation_id: correlation_id,
      field_photo_id: field_photo_id,
      locale: locale,
      question: question
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
    emit_interaction_completed(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      outcome: photo_outcome(cached[:analysis]),
      latency_ms: delivery_latency_ms
    )
  end

  def deliver(value, session:, filename:, account_id:, user_id:, correlation_id:, field_photo_id: nil, locale: nil, question: nil)
    session&.add_to_history(
      "assistant",
      value.fetch(:compact_context),
      user_id: user_id,
      correlation_id: correlation_id
    )

    rag_answer = nil
    if Rag::PhotoQuestionFlag.enabled? && question.present?
      rag_answer = answer_photo_question(
        question: question,
        photo_value: value,
        session: session,
        account_id: account_id,
        user_id: user_id,
        correlation_id: correlation_id,
        locale: locale
      )
      if rag_answer
        session&.add_to_history(
          "assistant",
          rag_answer.fetch(:answer),
          user_id: user_id,
          correlation_id: correlation_id
        )
      end
    end

    KbSyncBroadcaster.photo_analyzed(
      filenames: [ filename ],
      analysis: value.fetch(:analysis),
      canonical_name: value[:canonical_name],
      aliases: value[:aliases],
      account_id: account_id,
      correlation_id: correlation_id,
      field_photo_id: field_photo_id,
      thumbnail_url: field_photo_thumbnail_url(field_photo_id),
      response_locale: locale,
      answer: rag_answer&.fetch(:answer, nil),
      citations: rag_answer&.fetch(:citations, nil)
    )
  end

  # Runs the text-RAG turn anchored to the just-analyzed photo. Isolated in
  # its own rescue: a failure here must never cost the technician the vision
  # analysis that was already paid for and delivered above — see plan
  # foto_mas_pregunta_rag "Aislamiento de fallo obligatorio".
  def answer_photo_question(question:, photo_value:, session:, account_id:, user_id:, correlation_id:, locale:)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    account = session&.account || (account_id && Account.find_by(id: account_id))

    result = Rag::PhotoQuestionAnswerService.new(
      question: question,
      photo_value: photo_value,
      session: session,
      account: account,
      user_id: user_id,
      correlation_id: correlation_id,
      locale: locale
    ).call
    return nil unless result

    PilotUsageLog.log(
      "photo_question_answered",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: session&.id,
      correlation_id: correlation_id,
      route: "visual_query",
      route_taken: "photo_question_rag",
      question_sha256: Digest::SHA256.hexdigest(question),
      generation_mode: result[:generation_mode],
      outcome: photo_outcome(result[:answer]),
      latency_ms: elapsed_ms(started_at)
    )
    result
  rescue StandardError => e
    Rails.logger.warn("FieldPhotoAnalysisJob photo-question RAG failed: #{e.class}: #{e.message}")
    PilotUsageLog.log(
      "photo_question_failed",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: session&.id,
      correlation_id: correlation_id,
      route: "visual_query",
      stage: "rag",
      error_class: e.class.name,
      latency_ms: elapsed_ms(started_at)
    )
    # The vision bubble above already delivered — an exception here must
    # degrade to a localized note, never to the job's retry_on handler,
    # which would replace that already-paid-for analysis with a bare error.
    { answer: I18n.with_locale(locale) { I18n.t("rag.photo_question_unavailable") }, citations: [], generation_mode: nil }
  end

  def field_photo_thumbnail_url(field_photo_id)
    return nil if field_photo_id.blank?

    FieldPhoto.find_by(id: field_photo_id)&.thumbnail_data_url
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
    emit_interaction_completed(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      outcome: "failed",
      stage: "expired",
      error_class: "PhotoUploadExpired",
      latency_ms: nil
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

  # Single point of emission for the terminal state of a photo interaction —
  # RagController#ask never observes this route's actual completion (it only
  # sees the "accepted" acknowledgment), so this job is the correct border.
  def emit_interaction_completed(account_id:, user_id:, conversation_session_id:, correlation_id:,
                                 outcome:, latency_ms:, stage: nil, error_class: nil)
    PilotUsageLog.log(
      "interaction_completed",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      outcome: outcome,
      stage: stage,
      error_class: error_class,
      route: "visual_query",
      latency_ms: latency_ms
    )
  end

  # Reuses the abstention pattern already established for evidence-selection
  # telemetry (restriction 2) — no new regex.
  def photo_outcome(analysis_text)
    analysis_text.to_s.match?(Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN) ? "abstained" : "answered"
  end

  # A storage failure must never block diagnosis delivery to the technician.
  def persist_field_photo(image, account_id:, sha256:, filename:, content_type:, user_id:, conversation_session_id:)
    return nil if image.blank? || account_id.blank?

    FieldPhotoStore.persist!(
      account_id: account_id, sha256: sha256, binary: image[:binary],
      content_type: image[:content_type].presence || content_type,
      filename: image[:filename].presence || filename,
      thumbnail_binary: image[:thumbnail_binary], thumbnail_content_type: image[:thumbnail_content_type],
      thumbnail_width: image[:thumbnail_width], thumbnail_height: image[:thumbnail_height],
      user_id: user_id, conversation_session_id: conversation_session_id
    )&.id
  rescue StandardError => e
    Rails.logger.warn("FieldPhotoAnalysisJob persist failed account=#{account_id} reason=#{e.class}")
    nil
  end
end
