# frozen_string_literal: true

module FieldCases
  # Confirms one result for the origin case. The pending row, the attempt,
  # the execution token and the state revision must still match. A late
  # candidate leaves the winner's text, citations and revision in place.
  # The transaction only writes those columns. Jobs and model calls stay outside.
  class CloseTurn
    OUTCOMES = %w[completed failed].freeze

    def self.call(account:, user:, field_case_id:, turn_id:, attempt:, execution_token:,
                  expected_state_revision:, outcome:, response: nil, technical_state: nil,
                  prompt_reply: nil, checkpoint: nil, failure_stage: nil, failure_code: nil,
                  now: Time.current)
      new(
        account:, user:, field_case_id:, turn_id:, attempt:, execution_token:,
        expected_state_revision:, outcome:, response:, technical_state:,
        prompt_reply:, checkpoint:, failure_stage:, failure_code:, now:
      ).call
    end

    def initialize(account:, user:, field_case_id:, turn_id:, attempt:, execution_token:,
                   expected_state_revision:, outcome:, response:, technical_state:,
                   prompt_reply:, checkpoint:, failure_stage:, failure_code:, now:)
      @account = account
      @user = user
      @field_case_id = field_case_id
      @turn_id = turn_id
      @attempt = attempt
      @execution_token = execution_token
      @expected_state_revision = expected_state_revision
      @outcome = outcome
      @response = response
      @technical_state = technical_state
      @prompt_reply = prompt_reply
      @checkpoint = checkpoint
      @failure_stage = failure_stage
      @failure_code = failure_code
      @now = now
    end

    def call
      refusal = Guard.gate(account: @account, user: @user)
      return refusal if refusal

      prepared = prepare
      return prepared if prepared.is_a?(Result)

      decision = nil
      kase = nil
      turn = nil
      FieldCase.transaction do
        kase = Guard.locked_case(account: @account, user: @user, field_case_id: @field_case_id)
        return Result.new(:not_found) unless kase

        turn = kase.field_turns.lock.find_by(id: @turn_id)
        return Result.new(:not_found) unless turn

        unless winner?(kase, turn)
          decision = :lost
          next
        end

        apply!(kase, turn)
        decision = :won
      end
      kase.reload
      turn.reload
      Result.new(decision == :won ? :ok : :lost, field_case: kase, turn:)
    end

    private

    def prepare
      return invalid(:outcome) unless OUTCOMES.include?(@outcome)
      return invalid(:attempt) unless @attempt.is_a?(Integer) && @attempt.positive?
      return invalid(:expected_state_revision) unless @expected_state_revision.is_a?(Integer) && @expected_state_revision >= 0
      return invalid(:prompt_reply) unless prompt_ok?
      return invalid(:failure_code) unless failure_ok?

      error, @envelope = Payload.response_envelope(@response, completed: @outcome == "completed")
      return invalid(error) if error

      error, @checkpoint_value = Payload.checkpoint(@checkpoint)
      return invalid(error) if error

      if @outcome == "completed"
        return invalid(:technical_state) if @technical_state.nil?

        error, @state = Payload.state(@technical_state)
        return invalid(error) if error
      elsif !@technical_state.nil?
        error, @state = Payload.state(@technical_state)
        return invalid(error) if error
      end

      nil
    end

    def invalid(error)
      Result.new(:invalid, error:)
    end

    def prompt_ok?
      return true if @prompt_reply.nil?
      return false unless @prompt_reply.is_a?(String)

      @prompt_reply.length <= Payload::PROMPT_REPLY_MAX
    end

    def failure_ok?
      if @outcome == "failed"
        return false unless @failure_code.to_s.match?(Payload::FAILURE_FORMAT)
        return false if @failure_stage.present? && !@failure_stage.to_s.match?(Payload::FAILURE_FORMAT)

        return true
      end

      @failure_code.nil? && @failure_stage.nil?
    end

    def winner?(kase, turn)
      return false unless turn.status == "pending"
      return false unless turn.attempt == @attempt
      return false unless kase.state_revision == @expected_state_revision
      return false unless turn.base_state_revision == @expected_state_revision

      same_token?(turn.execution_token, @execution_token.to_s)
    end

    def same_token?(stored, given)
      left = stored.to_s
      return false if left.blank? || left.bytesize != given.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, given)
    end

    def apply!(kase, turn)
      new_revision = kase.state_revision + 1
      applied_state = @state.nil? ? kase.technical_state : @state
      turn.update_columns( # rubocop:disable Rails/SkipsModelValidations -- locked row; checks enforce the result
        status: @outcome,
        phase: @outcome == "completed" ? "published" : "failed",
        response: @envelope,
        prompt_reply: @prompt_reply,
        checkpoint: @checkpoint_value,
        failure_code: @failure_code,
        failure_stage: @failure_stage,
        result_state_revision: new_revision,
        completed_at: @now,
        updated_at: @now
      )
      kase.update_columns( # rubocop:disable Rails/SkipsModelValidations -- same locked case; do not reload the owner
        technical_state: applied_state,
        state_revision: new_revision,
        last_activity_at: @now,
        title: Payload.title_from(applied_state, kase.title),
        updated_at: @now
      )
    end
  end
end
