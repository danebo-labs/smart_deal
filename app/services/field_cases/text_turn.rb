# frozen_string_literal: true

module FieldCases
  class TextTurn
    def initialize(admission, account:, user:)
      @case = admission.field_case
      @turn = admission.turn
      @account = account
      @user = user
    end

    def context
      focus = Pins.resolve(@case.document_focus, account: @account)
      TurnContext.build(@case, focus:) if focus
    end

    def complete(json, context, prompt_reply:)
      json = json.stringify_keys
      close(
        outcome: "completed",
        response: {
          published_text: json.fetch("answer"),
          citations: json.fetch("citations"),
          provenance: json.fetch("provenance_segments"),
          render: json.except("answer", "citations", "provenance_segments", "session_id", "correlation_id")
        },
        technical_state: context.technical_state,
        checkpoint: context.active_episode,
        prompt_reply: prompt_reply&.first(Payload::PROMPT_REPLY_MAX)
      )
    end

    def fail(code, message)
      close(
        outcome: "failed", failure_code: code, failure_stage: "text",
        response: { render: { status: "error", message: message } }
      )
    end

    def self.chat_response(turn)
      saved = turn.response || {}
      saved.fetch("render", {}).merge(
        "answer" => saved["published_text"],
        "citations" => saved.fetch("citations", []),
        "provenance_segments" => saved.fetch("provenance", []),
        "correlation_id" => turn.correlation_id,
        "field_case_id" => turn.field_case_id,
        "field_turn" => Presenter.turn_hash(turn)
      )
    end

    private

    def close(**attributes)
      CloseTurn.call(
        account: @account, user: @user, field_case_id: @case.id, turn_id: @turn.id,
        attempt: @turn.attempt, execution_token: @turn.execution_token,
        expected_state_revision: @turn.base_state_revision, **attributes
      )
    end
  end
end
