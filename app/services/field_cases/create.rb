# frozen_string_literal: true

module FieldCases
  # Opens a case with no manuals. A repeated creation key returns that case
  # and does not clear pins added after the first request.
  class Create
    def self.call(account:, user:, creation_key: nil, now: Time.current)
      new(account:, user:, creation_key:, now:).call
    end

    def initialize(account:, user:, creation_key:, now:)
      @account = account
      @user = user
      @creation_key = creation_key
      @now = now
    end

    def call
      refusal = Guard.gate(account: @account, user: @user)
      return refusal if refusal

      key = normalized_key
      return Result.new(:invalid, error: :creation_key) if key == :invalid

      created = false
      kase = nil
      FieldCase.transaction do
        if key
          existing = FieldCase.find_by(account_id: @account.id, user_id: @user.id, creation_key: key)
          if existing
            kase = existing
            next
          end
        end

        kase = FieldCase.create!(
          account: @account,
          user: @user,
          creation_key: key,
          episode_id: FieldCase.generate_episode_id,
          mode: "resumable",
          title: nil,
          opened_at: @now,
          last_activity_at: @now,
          schema_version: FieldCase::SCHEMA_VERSION,
          state_revision: 0,
          last_sequence: 0,
          technical_state: {},
          document_focus: []
        )
        created = true
      end
      Result.new(:ok, field_case: kase, created:, payload: Presenter.case_hash(kase))
    rescue ActiveRecord::RecordNotUnique
      if key.is_a?(String)
        existing = FieldCase.find_by(account_id: @account.id, user_id: @user.id, creation_key: key)
        return Result.new(:ok, field_case: existing, payload: Presenter.case_hash(existing)) if existing
      end

      raise
    end

    private

    def normalized_key
      return nil if Payload.blank_key?(@creation_key)
      return :invalid unless Payload.key?(@creation_key)

      @creation_key.to_s
    end
  end
end
