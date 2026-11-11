# frozen_string_literal: true

module Rag
  # One write path for the controller and the direct runner.
  #
  # persist! returns whatever ConversationSession#record_assistant_turn! returns.
  # On the direct case path that value is a ConversationSession::CaseWriteConflict
  # when the write is dropped:
  # - status "stale_episode": expected_episode_id no longer matches the row.
  # - status "case_conflict": the episode matches, but the case snapshot revision
  #   changed after this turn was generated.
  # The row is not updated. Citations from the dropped answer are not published.
  # The caller shows conflict_answer and does not call a model again.
  class CompanionCaseWrite
    class << self
      def persist!(session, result, user_id:, expected_episode_id:, focus_ids: nil)
        kwargs = {
          user_id: user_id,
          correlation_id: result.correlation_id,
          pending_question: result.pending_question,
          expected_episode_id: expected_episode_id,
          focus_ids: focus_ids.nil? ? session.focus_document_ids : focus_ids,
          prompt_reply: result.respond_to?(:history_answer) ? result.history_answer : nil
        }
        if result.respond_to?(:case_outcome) && result.case_outcome.present?
          kwargs[:case_evidence] = result.case_evidence
          kwargs[:outcome] = result.case_outcome
          kwargs[:expected_case_revision] = result.expected_case_revision.to_i
        end
        written = session.record_assistant_turn!(result.answer.to_s, **kwargs)
        record_conflict(written)
        written
      end

      def conflict?(written)
        written.is_a?(ConversationSession::CaseWriteConflict)
      end

      def conflict_answer(locale)
        I18n.t("rag.case_write_conflict", locale: locale)
      end

      private

      def record_conflict(written)
        return unless conflict?(written)
        return unless ValidationCapture.active?

        ValidationCapture.record(
          "case_write_conflict",
          "status" => written.status,
          "expected_episode_id" => written.expected_episode_id,
          "current_episode_id" => written.current_episode_id,
          "expected_revision" => written.expected_revision,
          "current_revision" => written.current_revision,
          "correlation_id" => written.correlation_id
        )
      end
    end
  end
end
