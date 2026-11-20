# frozen_string_literal: true

module FieldCases
  # The text pipeline reduces a private snapshot. Only CloseTurn can make
  # these changes visible to another request.
  class TurnContext < ConversationSession
    def self.build(kase, focus:)
      seed = kase.technical_state.deep_dup
      new(
        account: kase.account,
        user_id: kase.user_id,
        channel: "web",
        active_episode: seed.except("case_evidence"),
        case_evidence: seed.fetch("case_evidence", {}),
        document_focus: focus
      ).tap { |context| context.restore_history(kase) }
    end

    def restore_history(kase)
      @case_id = kase.id
      @case_episode_id = kase.episode_id
      @case_opened_at = kase.opened_at.change(usec: 0)
      if active_episode.present?
        self.active_episode = active_episode.merge("updated_at" => Time.current.iso8601)
      end
      self.conversation_history = kase.field_turns.where(status: "completed")
        .order(sequence: :desc).limit(EPISODE_MAX_USER_MESSAGES).reverse.flat_map do |turn|
          [
            history_message("user", turn.message, user_id: user_id, correlation_id: turn.correlation_id)
              .merge("ts" => turn.admitted_at.iso8601),
            history_message("assistant", turn.response.fetch("published_text"),
              user_id: user_id, correlation_id: turn.correlation_id, prompt_reply: restored_reply(turn))
              .merge("ts" => turn.completed_at.iso8601)
          ]
        end
    end

    def start_photo_turn!(turn)
      if active_episode.blank?
        episode = open_owner_episode(turn.correlation_id, turn.admitted_at, Rag::AnswerContract::VERSION)
        update!(active_episode: episode.to_h)
      end
      return if turn.message.blank?

      record_user_turn!(turn.message, user_id: user_id, correlation_id: turn.correlation_id,
                        now: turn.admitted_at, locale: turn.locale)
    end

    def case_photo_context
      Rag::ActivePhotoContext.resolve(episode: Rag::ActiveEpisode.parse(active_episode), viewer_account: account)
    end

    def technical_state
      active_episode.merge("case_evidence" => case_evidence)
    end

    # The next turn interprets short replies against the question the
    # technician actually saw. Preserve structured targets when they match.
    def capture_pending!(result)
      # With FIELD_CHECK_OUTCOME the generation already wrote the pending
      # through Rag::PendingQuestion.from_publication, for text and photo.
      return if Rag::CheckOutcomeFlag.enabled?
      return unless result.case_outcome == "published"

      followup = Rag::PendingQuestion.followup_line(result.answer.to_s, locale: result.response_locale)
      return if followup.blank?

      proposed = result.pending_question
      return if proposed&.dig("question") == followup

      current = Rag::ActiveEpisode.parse(active_episode).pending_question
      shown = current&.dig("shown")
      candidate = if current&.dig("question") == followup
        current.except("shown")
      else
        { "type" => "documented_context", "question" => followup,
          "targets" => (shown["targets"].presence if shown&.dig("question") == followup) || [ { "item" => followup } ] }
      end
      result.pending_question = Rag::PendingQuestion.coerce(candidate)
    end

    # A photo answer is not written through record_assistant_turn!. Its
    # question becomes the pending the same way a text answer's does, so the
    # next turn is interpreted against the question the technician saw.
    # install_pending! restores the episode when the budget refuses it.
    def install_published_pending!(question, correlation_id:)
      return unless Rag::CheckOutcomeFlag.enabled? && question.is_a?(Hash)

      episode = Rag::ActiveEpisode.parse(active_episode)
      return if episode.blank?

      Rag::ActiveEpisodeTurn.install_pending!(episode, question, correlation_id)
      update!(active_episode: episode.to_h)
    end

    def case_opened_at
      @case_opened_at
    end

    attr_reader :case_id

    # A completed turn of this case, found by the correlation id a stored
    # reply carries, plus the text published by the completed turn before
    # it. The ordinary history keeps three turns; a reopened case can hold
    # replies to an older one. This reads FieldTurn only when asked, once per
    # correlation id, and never widens conversation_history. Nil when the
    # case or the completed turn is not there: the caller keeps the stored
    # state and records which reference was missing.
    def case_turn_reference(correlation_id)
      return nil if @case_id.nil? || correlation_id.blank?

      key = correlation_id.to_s
      @case_turn_references ||= {}
      return @case_turn_references[key] if @case_turn_references.key?(key)

      @case_turn_references[key] = load_case_turn_reference(key)
    end

    # ActiveRecord instantiate copies columns, not this window. The photo
    # answer reads a frozen snapshot, so the case open time and the case id
    # have to travel with it. Without that time the floor is the episode
    # open time, then the four-hour window. It is never nil.
    def copy_case_window_from(source)
      opened = source.case_opened_at if source.respond_to?(:case_opened_at)
      @case_opened_at = opened if opened
      @case_id ||= source.case_id if source.respond_to?(:case_id)
    end

    def episode_history_cutoff(now = Time.current)
      # The opening turn can be admitted in the second before its interpreter
      # opens the episode. Its timestamp is still part of this case.
      return @case_opened_at if @case_opened_at

      now = Time.current if now.nil?
      parsed = Rag::ActiveEpisode.parse(active_episode, now: now)
      opened = parsed.blank? ? nil : parse_history_ts(parsed.opened_at)
      opened || super
    end

    def with_lock
      yield
    end

    def update!(attributes)
      state = attributes[:active_episode]
      if state.present?
        attributes = attributes.merge(active_episode: state.merge("episode_id" => @case_episode_id))
        if active_episode.present? && state["opened_by"] != active_episode["opened_by"]
          attributes[:case_evidence] = {}
        end
      end
      assign_attributes(attributes)
      true
    end

    private

    def load_case_turn_reference(correlation_id)
      completed = FieldTurn.where(field_case_id: @case_id, status: "completed")
      sequence, message = completed.where(correlation_id: correlation_id).pick(:sequence, :message)
      return nil if sequence.nil?

      prior = completed.where(sequence: ...sequence).order(sequence: :desc)
        .pick(Arel.sql("response->>'published_text'"))
      { sequence: sequence, message: message.to_s, prior_published: prior }
    end

    def restored_reply(turn)
      return turn.prompt_reply unless turn.kind == "photo"

      summary = turn.response.dig("render", "visual_summary")
      [ ("[FOTO] #{summary}" if summary.present?), turn.prompt_reply ].compact.uniq.join("\n")
    end

    def episode_recording?
      true
    end

    def open_owner_episode(...)
      super.tap { |episode| episode.episode_id = @case_episode_id }
    end
  end
end
