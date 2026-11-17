# frozen_string_literal: true

module FieldCases
  # Authorized reads. Pending, completed and failed turns come from the rows,
  # in sequence order. Nothing here calls a model.
  class Read
    def self.list(account:, user:, cursor: nil, limit: nil)
      new(account:, user:).list(cursor:, limit:)
    end

    def self.fetch(account:, user:, field_case_id:, after_sequence: nil, limit: nil)
      new(account:, user:).fetch(field_case_id:, after_sequence:, limit:)
    end

    def self.turn(account:, user:, field_case_id:, turn_id:)
      new(account:, user:).turn(field_case_id:, turn_id:)
    end

    def initialize(account:, user:)
      @account = account
      @user = user
    end

    def list(cursor:, limit:)
      refusal = Guard.gate(account: @account, user: @user)
      return refusal if refusal

      bounded = Payload.limit(limit)
      return Result.new(:invalid, error: :limit) unless bounded

      time, id, error = Payload.cursor(cursor)
      return Result.new(:invalid, error:) if error

      scope = FieldCase.where(account_id: @account.id, user_id: @user.id)
      scope = scope.where("(last_activity_at, id) < (?, ?)", time, id) if time
      rows = scope.order(last_activity_at: :desc, id: :desc).limit(bounded + 1).to_a
      more = rows.size > bounded
      rows = rows.first(bounded)
      Result.new(:ok, payload: {
        "cases" => rows.map { |row| Presenter.case_hash(row) },
        "next_cursor" => more ? Payload.encode_cursor(rows.last) : nil
      })
    end

    def fetch(field_case_id:, after_sequence:, limit:)
      refusal = Guard.gate(account: @account, user: @user)
      return refusal if refusal

      kase = owned_case(field_case_id)
      return Result.new(:not_found) unless kase

      page = turn_page(kase, after_sequence:, limit:)
      return page if page.is_a?(Result)

      Result.new(:ok, field_case: kase, payload: {
        "case" => Presenter.case_hash(kase),
        "turns" => page.fetch(:turns).map { |turn| Presenter.turn_hash(turn) },
        "next_after_sequence" => page.fetch(:next_after)
      })
    end

    def turn(field_case_id:, turn_id:)
      refusal = Guard.gate(account: @account, user: @user)
      return refusal if refusal

      kase = owned_case(field_case_id)
      return Result.new(:not_found) unless kase

      number = Integer(turn_id, exception: false)
      record = number&.positive? ? kase.field_turns.find_by(id: number) : nil
      return Result.new(:not_found) unless record

      Result.new(:ok, field_case: kase, turn: record, payload: {
        "case" => Presenter.case_hash(kase),
        "turn" => Presenter.turn_hash(record)
      })
    end

    private

    def owned_case(field_case_id)
      number = Integer(field_case_id, exception: false)
      return nil unless number&.positive?

      FieldCase.find_by(id: number, account_id: @account.id, user_id: @user.id)
    end

    def turn_page(kase, after_sequence:, limit:)
      bounded = Payload.limit(limit)
      return Result.new(:invalid, error: :limit) unless bounded

      after = Payload.after_sequence(after_sequence)
      return Result.new(:invalid, error: :after_sequence) unless after

      rows = kase.field_turns.where("sequence > ?", after).order(:sequence).limit(bounded + 1).to_a
      more = rows.size > bounded
      rows = rows.first(bounded)
      { turns: rows, next_after: more ? rows.last.sequence : nil }
    end
  end
end
