# frozen_string_literal: true

module FieldCases
  # Opens a case and admits its first turn together. A failed admission
  # leaves no empty case. The same creation key and submission return the turn
  # already stored.
  class OpenText
    def self.call(account:, user:, creation_key:, client_submission_id:, message:, document_ids: [], photo: nil, locale: nil, now: Time.current)
      new(account:, user:, creation_key:, client_submission_id:, message:, document_ids:, photo:, locale:, now:).call
    end

    def initialize(account:, user:, creation_key:, client_submission_id:, message:, document_ids:, photo:, locale:, now:)
      @account = account
      @user = user
      @creation_key = creation_key
      @client_submission_id = client_submission_id
      @message = message
      @document_ids = document_ids
      @now = now
      @photo = photo
      @locale = locale
    end

    def call
      refusal = Guard.gate(account: @account, user: @user)
      return refusal if refusal

      key = @creation_key.to_s
      text = @message.is_a?(String) ? @message.strip : nil
      return invalid(:creation_key) unless Payload.key?(key)
      return invalid(:submission_id) unless Payload.key?(@client_submission_id)
      return invalid(:message) if text.nil? || (!@photo && text.blank?) || text.length > Payload::MESSAGE_MAX

      ids = normalized_document_ids
      return invalid(:pins) if ids.nil?

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
        pinned = attach_pins(kase, ids)
        unless pinned.ok?
          admission = pinned
          if created_now
            rolled_back = true
            raise ActiveRecord::Rollback
          end

          next
        end
        admission = AdmitTurn.call(
          account: @account, user: @user, field_case_id: kase.id,
          client_submission_id: @client_submission_id, message: text, now: @now, **attachment
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

      pinned = attach_pins(kase, ids)
      return pinned unless pinned.ok?

      AdmitTurn.call(
        account: @account, user: @user, field_case_id: kase.id,
        client_submission_id: @client_submission_id, message: text, now: @now, **attachment
      )
    end

    private

    def attachment
      @photo ? { kind: "photo", field_photo_id: @photo.id, locale: @locale } : {}
    end

    def invalid(error)
      Result.new(:invalid, error:)
    end

    def normalized_document_ids
      raw = @document_ids
      return [] if raw.nil?
      return nil unless raw.is_a?(Array)
      return nil if raw.size > Payload::PIN_MAX

      ids = raw.map { |value| Integer(value, exception: false) }
      return nil if ids.any? { |id| id.nil? || id <= 0 }
      return nil if ids.uniq.size != ids.size

      ids
    end

    # The manuals chosen on the empty chat. A later retry of the same send
    # leaves the focus already stored with the first turn.
    def attach_pins(kase, ids)
      return Result.new(:ok, field_case: kase) if ids.empty? || kase.last_sequence.positive?

      ids.each do |id|
        result = Pins.change(account: @account, user: @user, field_case_id: kase.id, document_id: id)
        return result unless result.ok?
      end
      Result.new(:ok, field_case: kase.reload)
    end
  end
end
