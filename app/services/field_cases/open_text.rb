# frozen_string_literal: true

module FieldCases
  # Opens a case and admits its first text turn together. A failed admission
  # leaves no empty case. The same creation key and submission return the turn
  # already stored.
  class OpenText
    def self.call(account:, user:, creation_key:, client_submission_id:, message:, now: Time.current)
      new(account:, user:, creation_key:, client_submission_id:, message:, now:).call
    end

    def initialize(account:, user:, creation_key:, client_submission_id:, message:, now:)
      @account = account
      @user = user
      @creation_key = creation_key
      @client_submission_id = client_submission_id
      @message = message
      @now = now
    end

    def call
      refusal = Guard.gate(account: @account, user: @user)
      return refusal if refusal

      key = @creation_key.to_s
      text = @message.is_a?(String) ? @message.strip : nil
      return invalid(:creation_key) unless Payload.key?(key)
      return invalid(:submission_id) unless Payload.key?(@client_submission_id)
      return invalid(:message) if text.blank? || text.length > Payload::MESSAGE_MAX

      admission = nil
      rolled_back = false
      FieldCase.transaction(requires_new: true) do
        kase = FieldCase.lock.find_by(account_id: @account.id, user_id: @user.id, creation_key: key)
        created_now = kase.nil?
        if created_now
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
        end
        admission = AdmitTurn.call(
          account: @account, user: @user, field_case_id: kase.id,
          client_submission_id: @client_submission_id, message: text, now: @now
        )
        if created_now && !admission.ok?
          rolled_back = true
          raise ActiveRecord::Rollback
        end
      end
      return Result.new(admission.status, error: admission.error) if rolled_back

      admission
    rescue ActiveRecord::RecordNotUnique
      kase = FieldCase.find_by(account_id: @account.id, user_id: @user.id, creation_key: key)
      return invalid(:creation_key) unless kase

      AdmitTurn.call(
        account: @account, user: @user, field_case_id: kase.id,
        client_submission_id: @client_submission_id, message: text, now: @now
      )
    end

    private

    def invalid(error)
      Result.new(:invalid, error:)
    end
  end
end
