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

      history = conversation_history.last(MAX_HISTORY - 1)
      history << history_message("user", turn.message, user_id: user_id, correlation_id: turn.correlation_id)
      update!(conversation_history: history)
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

    def case_opened_at
      @case_opened_at
    end

    # ActiveRecord instantiate copies columns, not this window. The photo
    # answer reads a frozen snapshot, so the case open time has to travel
    # with it. Without that time the floor is the episode open time, then
    # the four-hour window. It is never nil.
    def copy_case_window_from(source)
      opened = source.case_opened_at if source.respond_to?(:case_opened_at)
      @case_opened_at = opened if opened
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
