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
    Rag::TurnEvidence.log(
      correlation_id: args[:correlation_id],
      route: "visual_query",
      outcome: "failed",
      original_query: args[:question],
      effective_query: args[:question],
      answer: I18n.with_locale(locale) { I18n.t("rag.photo_analysis_failed") }
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
              conversation_session_id: nil, locale: nil, correlation_id: nil, field_photo_id: nil, question: nil,
              continuity: nil, expected_episode_id: nil)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    locale = locale.to_s.presence || I18n.default_locale.to_s
    correlation_id ||= "photo:#{SecureRandom.uuid}"
    session = conversation_session_id ? ConversationSession.find_by(id: conversation_session_id) : nil
    if session && account_id && session.account_id != account_id
      raise ArgumentError, "ConversationSession #{session.id} is not owned by account #{account_id}"
    end

    if continuity.to_s == "reuse"
      reuse_stored_observation(
        field_photo_id: field_photo_id,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        session: session,
        filename: filename,
        locale: locale,
        correlation_id: correlation_id,
        question: question,
        started_at: started_at,
        expected_episode_id: expected_episode_id
      )
      return
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
        image_sha256: image_sha256,
        question: question
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

    if field_photo_id.blank?
      field_photo_id = persist_field_photo(
        image, account_id: account_id, sha256: image_sha256, filename: filename,
        content_type: content_type, user_id: user_id, conversation_session_id: conversation_session_id
      )
    end

    photo_intent = Rag::PhotoIntent.resolve(
      question: question,
      episode_state: session&.active_episode,
      history: session&.conversation_history,
      now: Time.current
    )
    result = FieldPhotoAnalysisService.new(
      binary: image.fetch(:binary),
      content_type: image[:content_type].presence || content_type,
      filename: image[:filename].presence || filename,
      locale: locale,
      account_id: account_id,
      user_id: user_id,
      conv_session_id: conversation_session_id,
      correlation_id: correlation_id,
      photo_intent: photo_intent
    ).call

    acceptance = store_visual_observation(
      result, field_photo_id: field_photo_id, account_id: account_id, correlation_id: correlation_id
    )
    if continuity.to_s == "reread"
      log_observation_reread(
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        image_sha256: image_sha256
      )
    end

    display_value = photo_value(result)
    evidence_value = evidence_from(acceptance)
    delivered = deliver(
      display_value,
      evidence_value: evidence_value,
      session: session,
      filename: filename,
      account_id: account_id,
      user_id: user_id,
      correlation_id: correlation_id,
      field_photo_id: field_photo_id,
      image_sha256: image_sha256,
      locale: locale,
      question: question,
      photo_intent: photo_intent,
      expected_episode_id: expected_episode_id
    )
    PilotUsageLog.log(
      "photo_completed",
      **usage_fields(
        display_value,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        image_sha256: image_sha256
      )
    )
    emit_interaction_completed(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      outcome: delivered.fetch(:outcome),
      latency_ms: elapsed_ms(started_at),
      original_query: question,
      effective_query: delivered[:effective_query] || question,
      answer: delivered[:answer],
      citations: delivered[:citations],
      photo: {
        "intent_source" => photo_intent.is_a?(Hash) ? (photo_intent["source"] || photo_intent[:source]) : nil,
        "target_visible" => display_value[:target_visible]
      }
    )
  ensure
    FieldPhotoPendingImageStore.delete(token: image_token, account_id: account_id)
  end

  private

  def reuse_stored_observation(field_photo_id:, account_id:, user_id:, conversation_session_id:, session:,
                               filename:, locale:, correlation_id:, question:, started_at:, expected_episode_id: nil)
    photo = account_id && FieldPhoto.where(account_id: account_id).find_by(id: field_photo_id)
    observation = photo && FieldPhotoObservation.sanitize(photo.visual_observation)
    if observation.nil?
      broadcast_missing_observation(
        filename: filename,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        locale: locale,
        question: question,
        started_at: started_at,
        field_photo_id: photo&.id
      )
      return
    end

    PilotUsageLog.log(
      "photo_observation_reused",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      route: "visual_query",
      cache_status: "reused",
      image_digest_prefix: photo.sha256.to_s.first(12)
    )
    value = FieldPhotoObservation.reading_value(observation)
    delivered = deliver(
      value,
      evidence_value: value,
      session: session,
      filename: filename,
      account_id: account_id,
      user_id: user_id,
      correlation_id: correlation_id,
      field_photo_id: photo.id,
      image_sha256: photo.sha256,
      locale: locale,
      question: question,
      photo_intent: nil,
      expected_episode_id: expected_episode_id
    )
    emit_interaction_completed(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      outcome: delivered.fetch(:outcome),
      latency_ms: elapsed_ms(started_at),
      original_query: question,
      effective_query: delivered[:effective_query] || question,
      answer: delivered[:answer],
      citations: delivered[:citations],
      photo: { "target_visible" => value[:target_visible] }
    )
  end

  def broadcast_missing_observation(filename:, account_id:, user_id:, conversation_session_id:,
                                    correlation_id:, locale:, question:, started_at:, field_photo_id:)
    message = Rag::PhotoObservationContinuity::MISSING_PHOTO_MESSAGE
    KbSyncBroadcaster.photo_question_answered(
      answer: message,
      citations: [],
      provenance_segments: Rag::ProvenanceSegmenter.call(answer: message, citations: []),
      account_id: account_id,
      correlation_id: correlation_id,
      response_locale: locale,
      field_photo_id: field_photo_id
    )
    emit_interaction_completed(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      outcome: "answered",
      latency_ms: elapsed_ms(started_at),
      original_query: question,
      effective_query: question,
      answer: message
    )
  end

  def log_observation_reread(account_id:, user_id:, conversation_session_id:, correlation_id:, image_sha256:)
    PilotUsageLog.log(
      "photo_observation_reread",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      route: "visual_query",
      cache_status: "reread",
      image_digest_prefix: image_sha256.to_s.first(12)
    )
  end

  # Display of the paid reading continues when acceptance is not stored.
  # A failed accept does not replace a previous valid reading. Relevance and
  # target_visible are the values the analysis service already normalized.
  def store_visual_observation(result, field_photo_id:, account_id:, correlation_id:)
    photo = if field_photo_id.present? && account_id.present?
      FieldPhoto.where(account_id: account_id).find_by(id: field_photo_id)
    end
    acceptance = FieldPhotoObservation.accept!(
      photo: photo,
      parsed: result[:parsed],
      model_id: result[:model],
      target_visible: result[:target_visible],
      relevance_to_goal: result[:relevance_to_goal]
    )
    log_photo_observation_acceptance(
      acceptance, field_photo_id: field_photo_id, account_id: account_id, correlation_id: correlation_id
    )
    acceptance
  rescue StandardError => e
    Rails.logger.warn("FieldPhotoAnalysisJob observation persist failed account=#{account_id} reason=#{e.class}")
    acceptance = FieldPhotoObservation::Acceptance.new(status: "unavailable", observation: nil, reason: "persistence_failure")
    log_photo_observation_acceptance(
      acceptance, field_photo_id: field_photo_id, account_id: account_id, correlation_id: correlation_id
    )
    acceptance
  end

  def evidence_from(acceptance)
    return nil unless acceptance&.status == "stored"

    FieldPhotoObservation.reading_value(acceptance.observation)
  end

  def log_photo_observation_acceptance(acceptance, field_photo_id:, account_id:, correlation_id:)
    PilotUsageLog.log(
      "photo_observation_acceptance",
      result: acceptance.status,
      outcome_reason: acceptance.reason,
      field_photo_id: field_photo_id,
      account_id: account_id,
      correlation_id: correlation_id
    )
  end

  # A photo alone publishes the vision reading. A photo with a question
  # publishes one answer (CG-D19): the reading enters the prose of that single
  # RAG answer through the Photo Evidence block, and the chat never shows a
  # separate vision card, a placeholder, or a redraw. Returns the outcome
  # and the transmitted text, consumed by emit_interaction_completed.
  # Empty reading moves the active-photo pointer without copying another
  # photo's evidence or the rejected raw fields.
  BLANK_PHOTO_READING = {
    manufacturer: nil,
    model_visible: nil,
    relevance_to_goal: nil,
    target_visible: nil
  }.freeze

  def deliver(display_value, evidence_value:, session:, filename:, account_id:, user_id:, correlation_id:, field_photo_id: nil, locale: nil, question: nil, image_sha256: nil, photo_intent: nil, expected_episode_id: nil)
    write_state = session&.record_photo_observation!(
      photo_value: evidence_value || BLANK_PHOTO_READING,
      field_photo_id: field_photo_id,
      sha256: image_sha256,
      correlation_id: correlation_id,
      expected_episode_id: expected_episode_id
    )
    consequences = evidence_value.present? && write_state != :stale
    if consequences
      session&.record_assistant_turn!(
        evidence_value.fetch(:compact_context),
        user_id: user_id,
        correlation_id: correlation_id,
        expected_episode_id: expected_episode_id,
        writer: "photo_assistant"
      )
    end

    thumbnail_url = field_photo_thumbnail_url(field_photo_id)
    rag_answer = if consequences && Rag::PhotoQuestionFlag.enabled? && question.present?
      answer_photo_question(question: question, evidence_value: evidence_value, session: session,
                            account_id: account_id, user_id: user_id,
                            correlation_id: correlation_id, locale: locale,
                            field_photo_id: field_photo_id)
    end
    # nil when there is no question, or the flag flipped off between the check and the call
    if rag_answer.nil?
      summary = published_analysis(display_value, question: question, photo_intent: photo_intent, locale: locale)
      KbSyncBroadcaster.photo_analyzed(
        filenames: [ filename ], analysis: summary,
        canonical_name: display_value[:canonical_name], aliases: display_value[:aliases],
        account_id: account_id, correlation_id: correlation_id,
        field_photo_id: field_photo_id, thumbnail_url: thumbnail_url,
        response_locale: locale
      )
      return {
        outcome: photo_outcome(summary),
        answer: summary,
        effective_query: question,
        citations: nil
      }
    end

    unless rag_answer[:failed]
      session&.record_assistant_turn!(
        rag_answer.fetch(:answer),
        user_id: user_id,
        correlation_id: correlation_id,
        expected_episode_id: expected_episode_id,
        writer: "photo_assistant"
      )
    end
    KbSyncBroadcaster.photo_question_answered(
      answer: rag_answer.fetch(:answer), citations: rag_answer[:citations],
      provenance_segments: rag_answer[:provenance_segments],
      account_id: account_id, correlation_id: correlation_id, response_locale: locale,
      field_photo_id: field_photo_id, thumbnail_url: thumbnail_url,
      # The paid vision reading is not lost when the manuals could not be consulted.
      visual_summary: (display_value[:analysis] if rag_answer[:failed])
    )
    {
      outcome: rag_answer[:failed] ? "failed" : photo_outcome(rag_answer[:answer]),
      answer: rag_answer[:answer],
      effective_query: rag_answer[:effective_query] || question,
      citations: rag_answer[:retrieved_citations]
    }
  end

  # Runs the text-RAG turn anchored to the just-analyzed photo. Isolated in
  # its own rescue: a failure here must never cost the technician the vision
  # analysis that was already paid for and delivered above — see plan
  # foto_mas_pregunta_rag "Aislamiento de fallo obligatorio".
  def answer_photo_question(question:, evidence_value:, session:, account_id:, user_id:, correlation_id:, locale:,
                             field_photo_id: nil)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    account = session&.account || (account_id && Account.find_by(id: account_id))

    result = Rag::PhotoQuestionAnswerService.new(
      question: question,
      evidence_value: evidence_value,
      session: session,
      account: account,
      user_id: user_id,
      correlation_id: correlation_id,
      locale: locale,
      field_photo_id: field_photo_id
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
    # This text is the single answer the technician sees, next to the paid
    # vision reading — never the job's retry_on handler, which would replace
    # that reading with a bare error.
    unavailable = I18n.with_locale(locale) { I18n.t("rag.photo_question_unavailable") }
    {
      answer: unavailable,
      citations: [],
      provenance_segments: Rag::ProvenanceSegmenter.call(answer: unavailable, citations: []),
      generation_mode: nil,
      failed: true
    }
  end

  def field_photo_thumbnail_url(field_photo_id)
    return nil if field_photo_id.blank?

    FieldPhoto.find_by(id: field_photo_id)&.thumbnail_data_url
  end

  def published_analysis(value, question:, photo_intent:, locale:)
    if question.blank? && photo_intent.present?
      Rag::PhotoIntentRenderer.prose(reading: value, locale: locale)
    else
      value.fetch(:analysis)
    end
  end

  def photo_value(result)
    usage = result.fetch(:usage).to_h.deep_symbolize_keys
    model_id = result.fetch(:model).to_s
    model_id = "#{model_id}-direct" unless model_id.end_with?("-direct", "-batch")
    input_tokens = usage[:input_tokens].to_i
    output_tokens = usage[:output_tokens].to_i
    cache_read_tokens = usage[:cache_read_tokens]
    cache_creation_tokens = usage[:cache_creation_tokens]
    cost = BedrockQuery.new(
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cache_read_tokens: cache_read_tokens,
      cache_creation_tokens: cache_creation_tokens
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
      target_visible: result[:target_visible],
      relevance_to_goal: result[:relevance_to_goal],
      missing_view_or_detail: result[:missing_view_or_detail]
    }
  end

  def usage_fields(value, account_id:, user_id:, conversation_session_id:, correlation_id:,
                   image_sha256:)
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
                        correlation_id:, image_sha256:, question: nil)
    PilotUsageLog.log(
      "photo_failed",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      route: "visual_query",
      result: "expired",
      error_class: "PhotoUploadExpired",
      image_digest_prefix: image_sha256.to_s.first(12)
    )
    expired_answer = I18n.with_locale(locale) { I18n.t("rag.photo_upload_expired") }
    emit_interaction_completed(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      outcome: "failed",
      stage: "expired",
      error_class: "PhotoUploadExpired",
      latency_ms: nil,
      original_query: question,
      effective_query: question,
      answer: expired_answer
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
                                 outcome:, latency_ms:, stage: nil, error_class: nil,
                                 original_query: nil, effective_query: nil, answer: nil,
                                 citations: nil, photo: nil)
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
    chunk_ids, sources = Rag::TurnEvidence.evidence_from(citations)
    Rag::TurnEvidence.log(
      correlation_id: correlation_id,
      route: "visual_query",
      outcome: outcome,
      original_query: original_query,
      effective_query: effective_query.nil? ? original_query : effective_query,
      answer: answer,
      photo: photo,
      chunk_ids: chunk_ids,
      sources: sources
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
