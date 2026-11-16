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
              user_id: user_id, correlation_id: turn.correlation_id, prompt_reply: turn.prompt_reply)
              .merge("ts" => turn.completed_at.iso8601)
          ]
        end
    end

    def technical_state
      active_episode.merge("case_evidence" => case_evidence)
    end

    # Direct generation returns prose. Keep a standalone final question from
    # the guarded answer, using the same reply contract as planned questions.
    def capture_pending!(result)
      return if result.pending_question || result.case_outcome != "published"

      line = result.answer.to_s.rstrip.lines.last.to_s.strip
      question = line[/¿[^¿?]{1,158}\?\z/]
      question ||= line[/\A[^¿?]{1,159}\?\z/] if result.response_locale.to_s.start_with?("en")
      return unless question

      current = Rag::ActiveEpisode.parse(active_episode).pending_question
      candidate = { "type" => "documented_context", "question" => question, "targets" => [ { "item" => question } ] }
      result.pending_question = if current&.dig("type") != "documented_context"
        Rag::PendingQuestion.coerce(candidate)
      elsif current["question"] == question
        current
      else
        Rag::PendingQuestion.coerce(current.merge("shown" => candidate))
      end
    end

    def episode_history_cutoff(_now = Time.current)
      parse_history_ts(active_episode["opened_at"]) || @case_opened_at
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

    def open_owner_episode(...)
      super.tap { |episode| episode.episode_id = @case_episode_id }
    end
  end
end
