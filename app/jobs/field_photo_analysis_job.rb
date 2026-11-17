# frozen_string_literal: true

require "digest"

class FieldPhotoAnalysisJob < ApplicationJob
  queue_as do
    if Rag::LocalPassLedger.armed?
      ENV["RAG_PHOTO_WORKER_QUEUE"].presence || :default
    else
      :default
    end
  end
  around_perform :capture_guarded_photo
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
    failed_answer = I18n.with_locale(locale) { I18n.t("rag.photo_analysis_failed") }
    Rag::TurnEvidence.log(
      correlation_id: args[:correlation_id],
      route: "visual_query",
      outcome: "failed",
      original_query: args[:raw_question].nil? ? args[:question] : args[:raw_question],
      effective_query: args[:question],
      answer: failed_answer,
      account_id: args[:account_id]
    )
    Rag::DurableTrace.record_failure!(
      account_id: args[:account_id],
      user_id: args[:user_id],
      conversation_session_id: args[:conversation_session_id],
      correlation_id: args[:correlation_id],
      stage: "error",
      error: error,
      attempt: job.executions,
      job_id: job.job_id,
      outcome: "failed"
    )
    Rag::DurableTrace.record_terminal!(
      account_id: args[:account_id],
      user_id: args[:user_id],
      conversation_session_id: args[:conversation_session_id],
      correlation_id: args[:correlation_id],
      route: "visual_query",
      outcome: "failed",
      stage: "error",
      error_class: error.class.name,
      original_query: args[:raw_question].nil? ? args[:question] : args[:raw_question],
      effective_query: args[:question],
      answer: failed_answer,
      attempt: job.executions
    )
    KbSyncBroadcaster.failed(
      filenames: [ args[:filename].presence || "photo" ],
      account_id: args[:account_id],
      reason: "photo_analysis_error",
      message: I18n.with_locale(locale) { I18n.t("rag.photo_analysis_failed") },
      correlation_id: args[:correlation_id]
    )
  end

  def perform(**args)
    return perform_analysis(**args) unless args[:field_case_id]

    @case_photo = FieldCases::PhotoTurn.claim(**args)
    return unless @case_photo

    turn = @case_photo.turn
    photo = turn.field_photo
    context = @case_photo.context
    return @case_photo.fail("invalid_pins") unless context

    context.start_photo_turn!(turn)
    perform_analysis(
      image_token: nil, image_sha256: photo.sha256, filename: File.basename(photo.s3_key_original),
      content_type: photo.content_type, account_id: photo.account_id, user_id: turn.field_case.user_id,
      locale: turn.locale, correlation_id: turn.correlation_id, field_photo_id: photo.id,
      question: turn.message, raw_question: turn.message, expected_episode_id: context.live_episode_id,
      case_context: context
    )
  rescue StandardError => error
    raise unless @case_photo

    Rails.logger.warn("Case photo analysis failed: #{error.class}")
    failed = @case_photo.fail("analysis_failed")
    if failed.ok?
      turn = failed.turn
      Rag::DurableTrace.record_failure!(
        account_id: args[:account_id], user_id: args[:user_id], correlation_id: turn.correlation_id,
        stage: "vision", error: error, job_id: job_id, attempt: turn.attempt, outcome: "failed"
      )
    end
  end

  private

  def perform_analysis(image_token:, image_sha256:, filename:, content_type:, account_id:, user_id: nil,
              conversation_session_id: nil, locale: nil, correlation_id: nil, field_photo_id: nil, question: nil,
              raw_question: nil, continuity: nil, expected_episode_id: nil, case_context: nil)
    @technician_text = raw_question.nil? ? question.to_s : raw_question.to_s
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    locale = locale.to_s.presence || I18n.default_locale.to_s
    correlation_id ||= "photo:#{SecureRandom.uuid}"
    @durable_trace = Rag::DurableTrace.start_job(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      job_id: job_id,
      attempt: @case_photo&.turn&.attempt || [ executions.to_i, 1 ].max
    )
    if @case_photo
      turn = @case_photo.turn
      Rag::ValidationCapture.bind(field_case_id: turn.field_case_id, field_turn_id: turn.id)
      Rag::ValidationCapture.record("photo_attachment", "field_photo_id" => turn.field_photo_id, "attachment" => turn.attachment)
    end
    session = case_context || (ConversationSession.find_by(id: conversation_session_id) if conversation_session_id)
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
      photo = FieldPhoto.where(account_id: account_id, storage_scope: "").find_by(id: field_photo_id)
      photo = @case_photo.turn.field_photo if @case_photo
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
      return @case_photo.fail("photo_unavailable") if @case_photo

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

    if @photo_capture_dir
      path = @photo_capture_dir.join("worker-input.jpg")
      File.binwrite(path, image.fetch(:binary))
      path.chmod(0o600)
      Rag::ValidationCapture.record("photo_worker_input",
        "bytes" => path.size, "sha256" => Digest::SHA256.file(path).hexdigest, "declared_sha256" => image_sha256)
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

    visual_context = Rag::VisualTaskContext.build(
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
      visual_task_context: visual_context.to_h
    ).call

    accept = -> {
      store_visual_observation(
        result, field_photo_id: field_photo_id, account_id: account_id, correlation_id: correlation_id
      )
    }
    acceptance = @case_photo ? @case_photo.with_running_turn(&accept) : accept.call
    return unless acceptance
    if continuity.to_s == "reread"
      log_observation_reread(
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        image_sha256: image_sha256
      )
    end

    if @case_photo
      Rag::ValidationCapture.record(
        "photo_observation",
        "status" => acceptance.status, "reason" => acceptance.reason,
        "observation" => acceptance.observation, "visual_analysis" => result[:analysis]
      )
    end
    display_value = photo_value(result)
    evidence_value = evidence_from(acceptance)
    delivered = deliver(
      display_value,
      evidence_value: evidence_value,
      accepted_observation: acceptance.status == "stored" ? acceptance.observation : nil,
      session: session,
      filename: filename,
      account_id: account_id,
      user_id: user_id,
      correlation_id: correlation_id,
      field_photo_id: field_photo_id,
      image_sha256: image_sha256,
      locale: locale,
      question: question,
      visual_task: visual_context.visual_task,
      expected_episode_id: expected_episode_id
    )
    return unless delivered

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
      stage: delivered[:stage],
      error_class: delivered[:error_class],
      latency_ms: elapsed_ms(started_at),
      original_query: technician_question(question),
      effective_query: delivered[:effective_query] || question,
      answer: delivered[:answer],
      citations: delivered[:citations],
      generation_mode: delivered[:generation_mode],
      generation_context: delivered[:generation_context],
      generation_prompt_chars: delivered[:generation_prompt_chars],
      context_truncated: delivered[:context_truncated],
      photo: {
        "intent_source" => visual_context.visual_task&.dig("source"),
        "target_visible" => display_value[:target_visible]
      }
    )
  ensure
    Rag::DurableTrace.finish_job(@durable_trace)
    FieldPhotoPendingImageStore.delete(token: image_token, account_id: account_id)
  end

  def capture_guarded_photo
    unless Rag::LocalPassLedger.guard_requested? && Rag::WebRequestCapture.enabled?
      return yield
    end

    args = arguments.first.to_h.symbolize_keys
    correlation = args.fetch(:correlation_id)
    unless correlation.match?(/\A(?:photo|query):[a-f0-9-]+\z/)
      raise Rag::LocalPassLedger::Stop, "invalid_photo_correlation"
    end
    key = "worker-#{correlation.tr(':', '-')}"
    key += "-retry-#{executions}" if executions > 1
    @photo_capture_dir = Rails.root.join(Rag::WebRequestCapture::ROOT, Rag::WebRequestCapture.run_id, key)
    FileUtils.mkdir_p(@photo_capture_dir, mode: 0o700)
    Rag::ValidationCapture.capture do |events|
      Rag::ValidationCapture.bind(
        run_id: Rag::WebRequestCapture.run_id, account_id: args[:account_id], user_id: args[:user_id],
        session_id: args[:conversation_session_id], episode_id: args[:expected_episode_id],
        correlation_root: correlation
      )
      Rag::ValidationCapture.with_turn(correlation) do
        Rag::ValidationCapture.record("photo_worker", "job_id" => job_id, "execution" => executions)
        begin
          yield
        rescue Rag::LocalPassLedger::Stop => error
          Rag::ValidationCapture.record("photo_worker_refused", "reason" => error.message)
          KbSyncBroadcaster.failed(filenames: [ args[:filename] ], account_id: args[:account_id],
            reason: "local_pass_refused", correlation_id: correlation)
        rescue StandardError => error
          Rag::ValidationCapture.record("photo_worker_error", "error_class" => error.class.name)
          raise
        end
      end
    ensure
      Rag::WebRequestCapture.export!(events, key)
    end
  ensure
    Rag::LocalPassLedger.release_thread! if @photo_capture_dir
  end

  def reuse_stored_observation(field_photo_id:, account_id:, user_id:, conversation_session_id:, session:,
                               filename:, locale:, correlation_id:, question:, started_at:, expected_episode_id: nil)
    photo = account_id && FieldPhoto.where(account_id: account_id, storage_scope: "").find_by(id: field_photo_id)
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
      image_digest_prefix: photo.sha256.to_s.first(12),
      field_photo_id: photo.id,
      **photo_observation_fields(observation)
    )
    value = FieldPhotoObservation.reading_value(observation)
    delivered = deliver(
      value,
      evidence_value: value,
      accepted_observation: observation,
      session: session,
      filename: filename,
      account_id: account_id,
      user_id: user_id,
      correlation_id: correlation_id,
      field_photo_id: photo.id,
      image_sha256: photo.sha256,
      locale: locale,
      question: question,
      visual_task: nil,
      expected_episode_id: expected_episode_id,
      confirm_identity: true
    )
    emit_interaction_completed(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      outcome: delivered.fetch(:outcome),
      stage: delivered[:stage],
      error_class: delivered[:error_class],
      latency_ms: elapsed_ms(started_at),
      original_query: technician_question(question),
      effective_query: delivered[:effective_query] || question,
      answer: delivered[:answer],
      citations: delivered[:citations],
      generation_mode: delivered[:generation_mode],
      generation_context: delivered[:generation_context],
      generation_prompt_chars: delivered[:generation_prompt_chars],
      context_truncated: delivered[:context_truncated],
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
      original_query: technician_question(question),
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
      correlation_id: correlation_id,
      **photo_observation_fields(acceptance.observation)
    )
  end

  def photo_observation_fields(observation)
    reading = observation.to_h.stringify_keys
    {
      relevance_to_goal: reading["relevance_to_goal"],
      manufacturer: reading["manufacturer"],
      model: reading["model"].presence || reading["model_visible"].presence
    }
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

  def deliver(display_value, evidence_value:, session:, filename:, account_id:, user_id:, correlation_id:, field_photo_id: nil, locale: nil, question: nil, image_sha256: nil, visual_task: nil, expected_episode_id: nil, accepted_observation: nil, confirm_identity: false)
    write_state = session&.record_photo_observation!(
      photo_value: evidence_value || BLANK_PHOTO_READING,
      field_photo_id: field_photo_id,
      sha256: image_sha256,
      correlation_id: correlation_id,
      expected_episode_id: expected_episode_id
    )
    consequences = evidence_value.present? && write_state != :stale
    turn_context = if consequences
      session&.record_photo_assistant_context!(
        evidence_value.fetch(:compact_context),
        user_id: user_id,
        correlation_id: correlation_id,
        expected_episode_id: expected_episode_id,
        question: question,
        accepted_observation: accepted_observation,
        confirm_identity: confirm_identity
      )
    end
    history_state = turn_context&.status
    # :stale is the only photo-history result that stops the question path.
    # :not_recording still continues. The history write captures the generation
    # context before the lock is released. Bedrock uses that snapshot.
    photo_question = consequences && history_state != :stale &&
      (@case_photo || Rag::PhotoQuestionFlag.enabled?) && question.present?

    thumbnail_url = field_photo_thumbnail_url(field_photo_id) unless @case_photo
    rag_answer = if photo_question
      answer_photo_question(question: question, evidence_value: evidence_value, session: session,
                            account_id: account_id, user_id: user_id,
                            correlation_id: correlation_id, locale: locale,
                            field_photo_id: field_photo_id, accepted_observation: accepted_observation,
                            session_context_snapshot: turn_context&.session_context,
                            entity_s3_uris_snapshot: turn_context&.entity_s3_uris,
                            retrieval_question: turn_context&.retrieval_question,
                            equipment_identity: turn_context&.equipment_identity,
                            session_snapshot: turn_context&.session_snapshot)
    end
    if @case_photo
      summary = published_analysis(display_value, question: question, visual_task: visual_task, locale: locale)
      answer = rag_answer&.fetch(:answer) || summary
      return publish_case_photo(session, answer, rag_answer, summary, accepted_observation)
    end
    # nil when there is no question, or the flag flipped off between the check and the call
    if rag_answer.nil?
      summary = published_analysis(display_value, question: question, visual_task: visual_task, locale: locale)
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

    written = session&.record_assistant_turn!(
      rag_answer.fetch(:answer),
      user_id: user_id,
      correlation_id: correlation_id,
      expected_episode_id: expected_episode_id,
      pending_question: rag_answer[:pending_question],
      focus_ids: rag_answer[:focus_ids],
      prompt_reply: rag_answer[:failed] ? "" : rag_answer[:history_answer],
      outcome: rag_answer[:failed] ? "failed" : (rag_answer[:case_outcome] || rag_answer[:route_outcome]),
      case_evidence: rag_answer[:case_evidence],
      expected_case_revision: rag_answer[:expected_case_revision],
      writer: "photo_assistant"
    )
    if written == :stale || Rag::CompanionCaseWrite.conflict?(written)
      answer = Rag::CompanionCaseWrite.conflict_answer(locale)
      rag_answer = { answer: answer, failed: true, equipment_identity_reason: "stale_answer" }
    end
    Rag::ValidationCapture.record(
      "photo_answer_delivery", "answer" => rag_answer.fetch(:answer), "outcome" => photo_question_outcome(rag_answer),
      "field_photo_id" => field_photo_id, "correlation_id" => correlation_id,
      "generation_mode" => rag_answer[:generation_mode], "outcome_reason" => rag_answer[:equipment_identity_reason],
      "error_class" => rag_answer[:error_class]
    )
    KbSyncBroadcaster.photo_question_answered(
      answer: rag_answer.fetch(:answer), citations: rag_answer[:citations],
      provenance_segments: rag_answer[:provenance_segments],
      account_id: account_id, correlation_id: correlation_id, response_locale: locale,
      field_photo_id: field_photo_id, thumbnail_url: thumbnail_url,
      # The paid vision reading is not lost when the manuals could not be consulted.
      visual_summary: (display_value[:analysis] if rag_answer[:failed])
    )
    {
      outcome: photo_question_outcome(rag_answer),
      stage: ("photo_question_rag" if rag_answer[:failed]),
      error_class: rag_answer[:error_class],
      answer: rag_answer[:answer],
      effective_query: rag_answer[:effective_query] || question,
      citations: rag_answer[:retrieved_citations],
      generation_mode: rag_answer[:generation_mode],
      generation_context: rag_answer[:generation_context],
      generation_prompt_chars: rag_answer[:generation_prompt_chars],
      context_truncated: rag_answer[:context_truncated]
    }
  end

  def publish_case_photo(context, answer, rag_answer, summary, observation)
    if rag_answer&.dig(:failed)
      @case_photo.fail("photo_question_failed")
      return nil
    end

    citations = rag_answer&.dig(:citations) || []
    provenance = rag_answer&.dig(:provenance_segments) ||
      Rag::ProvenanceSegmenter.call(answer: answer, citations: citations, visual_observation: observation)
    saved = @case_photo.publish(answer:, citations:, provenance:, context:, visual_summary: summary)
    if saved.invalid?
      @case_photo.fail("invalid_photo_result")
      return nil
    end
    return unless saved.ok?

    Rag::ValidationCapture.record("published_answer", "answer" => answer, "citations" => citations)
    {
      outcome: photo_outcome(answer), answer:, citations: rag_answer&.dig(:retrieved_citations),
      effective_query: rag_answer&.dig(:effective_query) || @technician_text,
      **(rag_answer || {}).slice(:generation_mode, :generation_context, :generation_prompt_chars, :context_truncated)
    }
  end

  # Runs the text-RAG turn anchored to the just-analyzed photo. Isolated in
  # its own rescue: a failure here must never cost the technician the vision
  # analysis that was already paid for and delivered above — see plan
  # foto_mas_pregunta_rag "Aislamiento de fallo obligatorio".
  def answer_photo_question(question:, evidence_value:, session:, account_id:, user_id:, correlation_id:, locale:,
                             field_photo_id: nil, accepted_observation: nil, session_context_snapshot: nil,
                             entity_s3_uris_snapshot: nil, retrieval_question: nil, equipment_identity: nil, session_snapshot: nil)
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
      field_photo_id: field_photo_id,
      accepted_observation: accepted_observation,
      session_context_snapshot: session_context_snapshot,
      entity_s3_uris_snapshot: entity_s3_uris_snapshot,
      retrieval_question: retrieval_question,
      equipment_identity: equipment_identity,
      raw_question: @technician_text,
      session_snapshot: session_snapshot
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
      question_sha256: Digest::SHA256.hexdigest(technician_question(question)),
      generation_mode: result[:generation_mode],
      outcome: photo_question_outcome(result),
      stage: ("photo_question_rag" if result[:failed]),
      outcome_reason: result[:equipment_identity_reason],
      error_class: result[:error_class],
      latency_ms: elapsed_ms(started_at)
    )
    result
  rescue StandardError => e
    Rails.logger.warn("FieldPhotoAnalysisJob photo-question RAG failed correlation_id=#{correlation_id} error_class=#{e.class}")
    Rag::DurableTrace.record_failure!(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: session&.id,
      correlation_id: correlation_id,
      stage: "rag",
      error: e,
      outcome: "failed"
    )
    Rag::ValidationCapture.record(
      "photo_question_failure",
      "stage" => "rag",
      "error_class" => e.class.name,
      "backtrace" => Array(e.backtrace).first(12)
    )
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
      error_class: e.class.name,
      failed: true
    }
  end

  def photo_question_outcome(result)
    return "failed" if result[:failed]

    result[:route_outcome].presence&.to_s || photo_outcome(result[:answer])
  end

  def field_photo_thumbnail_url(field_photo_id)
    return nil if field_photo_id.blank?

    FieldPhoto.find_by(id: field_photo_id)&.thumbnail_data_url
  end

  def published_analysis(value, question:, visual_task:, locale:)
    if question.blank? && visual_task.present?
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
      original_query: technician_question(question),
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

  def technician_question(question)
    return @technician_text unless @technician_text.nil?

    question.to_s
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
                                 citations: nil, photo: nil, generation_mode: nil,
                                 generation_context: nil, generation_prompt_chars: nil,
                                 context_truncated: nil)
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
      latency_ms: latency_ms,
      generation_mode: generation_mode,
      generation_context: generation_context,
      generation_prompt_chars: generation_prompt_chars,
      context_truncated: context_truncated
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
      sources: sources,
      account_id: account_id
    )
    return if account_id.blank?

    Rag::DurableTrace.record_terminal!(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      route: "visual_query",
      outcome: outcome,
      stage: stage,
      error_class: error_class,
      original_query: original_query,
      effective_query: effective_query.nil? ? original_query : effective_query,
      answer: answer,
      chunk_ids: chunk_ids,
      sources: sources,
      photo: photo,
      generation_mode: generation_mode,
      generation_context: generation_context,
      generation_prompt_chars: generation_prompt_chars,
      context_truncated: context_truncated
    )
    return unless outcome.to_s == "failed"

    Rag::DurableTrace.record_failure!(
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      stage: stage,
      error_class: error_class,
      outcome: outcome
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
