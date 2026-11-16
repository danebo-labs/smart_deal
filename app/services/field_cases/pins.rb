# frozen_string_literal: true

module FieldCases
  # Replaces the manuals of one case. A new case is not given another case's
  # pins. A pending turn keeps the set it was admitted with.
  class Pins
    def self.call(account:, user:, field_case_id:, pins:)
      new(account:, user:, field_case_id:, pins:).call
    end

    def initialize(account:, user:, field_case_id:, pins:)
      @account = account
      @user = user
      @field_case_id = field_case_id
      @pins = pins
    end

    def call
      refusal = Guard.gate(account: @account, user: @user)
      return refusal if refusal

      error, entries = Payload.pins(@pins)
      return Result.new(:invalid, error:) if error

      kase = nil
      FieldCase.transaction do
        kase = Guard.locked_case(account: @account, user: @user, field_case_id: @field_case_id)
        return Result.new(:not_found) unless kase
        return Result.new(:conflict, error: :not_resumable, field_case: kase) unless kase.resumable?

        pending = kase.field_turns.find_by(status: "pending")
        return Result.new(:conflict, error: :case_busy, field_case: kase, turn: pending) if pending

        # Locked row. The focus array was already checked; do not reload the owner.
        kase.update_columns(document_focus: entries, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end
      Result.new(:ok, field_case: kase.reload, payload: Presenter.case_hash(kase))
    end
  end
end
