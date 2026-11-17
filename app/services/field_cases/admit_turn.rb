# frozen_string_literal: true

module FieldCases
  # Admits one submission. The client key is checked under the case lock
  # before a busy case is rejected. Sequence assignment and the pending row
  # commit together. No model call and no job run inside the transaction.
  class AdmitTurn
    LEASE = 10.minutes

    def self.call(account:, user:, field_case_id:, client_submission_id:, message: nil, kind: "text",
                  field_photo_id: nil, attachment_sha256: nil, content_type: nil, byte_size: nil,
                  correlation_id: nil, locale: nil, now: Time.current)
      new(
        account:, user:, field_case_id:, client_submission_id:, message:, kind:,
        field_photo_id:, attachment_sha256:, content_type:, byte_size:,
        correlation_id:, locale:, now:
      ).call
    end

    def initialize(account:, user:, field_case_id:, client_submission_id:, message:, kind:,
                   field_photo_id:, attachment_sha256:, content_type:, byte_size:,
                   correlation_id:, locale:, now:)
      @account = account
      @user = user
      @field_case_id = field_case_id
      @client_submission_id = client_submission_id
      @message = message
      @kind = kind
      @field_photo_id = field_photo_id
      @attachment_sha256 = attachment_sha256
      @content_type = content_type
      @byte_size = byte_size
      @correlation_id = correlation_id
      @locale = locale
      @now = now
    end

    def call
      refusal = Guard.gate(account: @account, user: @user)
      return refusal if refusal
      return invalid(:submission_id) unless Payload.key?(@client_submission_id)
      return invalid(:kind) unless FieldTurn::KINDS.include?(@kind)
      return invalid(:message) unless message_ok?
      return invalid(:locale) unless locale_ok?
      return invalid(:correlation_id) if @correlation_id.present? && !Payload.correlation_ok?(@correlation_id, @kind)

      photo = load_photo
      return invalid(:attachment) if photo == :missing

      error, descriptor, sha = Payload.attachment_for(
        photo: photo,
        sha256: @attachment_sha256,
        content_type: @content_type,
        byte_size: @byte_size
      )
      return invalid(error) if error
      return invalid(:attachment) if @kind == "photo" && sha.blank?

      @digest = Payload.digest(message: @message.to_s, attachment_sha256: sha)
      @correlation = @correlation_id.presence || Payload.correlation_for(@kind)
      @descriptor = descriptor
      @photo = photo

      turn = nil
      kase = nil
      created = false
      FieldCase.transaction do
        kase = Guard.locked_case(account: @account, user: @user, field_case_id: @field_case_id)
        return Result.new(:not_found) unless kase

        existing = kase.field_turns.find_by(client_submission_id: @client_submission_id)
        if existing
          if existing.input_digest == @digest
            expire_text_turn(existing)
            turn = existing
            next
          end

          return Result.new(:conflict, error: :submission_reused, field_case: kase, turn: existing)
        end

        return Result.new(:conflict, error: :not_resumable, field_case: kase) unless kase.resumable?

        pending = kase.field_turns.find_by(status: "pending")
        if pending && !expire_text_turn(pending)
          return Result.new(:conflict, error: :case_busy, field_case: kase, turn: pending)
        end

        sequence = kase.last_sequence + 1
        turn = kase.field_turns.create!(
          sequence:,
          client_submission_id: @client_submission_id,
          input_digest: @digest,
          correlation_id: @correlation,
          kind: @kind,
          message: @message.to_s,
          field_photo: photo,
          attachment: descriptor,
          locale: @locale.presence,
          status: "pending",
          phase: "queued",
          attempt: 1,
          execution_token: SecureRandom.uuid,
          base_state_revision: kase.state_revision,
          lease_expires_at: @now + LEASE,
          admitted_at: @now
        )
        # Locked row. Check constraints back the write; validations would reload the owner.
        kase.update_columns(last_sequence: sequence, last_activity_at: @now, updated_at: @now) # rubocop:disable Rails/SkipsModelValidations
        created = true
      end
      Result.new(:ok, field_case: kase.reload, turn: turn.reload, created:)
    rescue ActiveRecord::RecordNotUnique
      reconcile
    end

    private

    def expire_text_turn(turn)
      return false unless turn.kind == "text" && turn.status == "pending" && turn.lease_expires_at && turn.lease_expires_at <= @now

      turn.update!(status: "failed", phase: "failed", failure_code: "lease_expired", completed_at: @now)
      true
    end

    def invalid(error)
      Result.new(:invalid, error:)
    end

    def message_ok?
      return false unless @message.nil? || @message.is_a?(String)

      text = @message.to_s
      return false if text.length > Payload::MESSAGE_MAX
      return false if @kind == "text" && text.strip.empty?

      true
    end

    def locale_ok?
      return true if @locale.nil? || @locale == ""

      @locale.is_a?(String) && @locale.match?(/\A[a-zA-Z-]{2,16}\z/)
    end

    def load_photo
      return nil if @field_photo_id.blank?

      photo = FieldPhoto.find_by(id: @field_photo_id, account_id: @account.id)
      return :missing unless photo && (photo.storage_scope.blank? || photo.user_id == @user.id)

      photo
    end

    def reconcile
      kase = FieldCase.find_by(id: @field_case_id, account_id: @account.id, user_id: @user.id)
      return Result.new(:not_found) unless kase

      existing = kase.field_turns.find_by(client_submission_id: @client_submission_id)
      if existing
        if existing.input_digest == @digest
          return Result.new(:ok, field_case: kase, turn: existing)
        end

        return Result.new(:conflict, error: :submission_reused, field_case: kase, turn: existing)
      end

      pending = kase.field_turns.find_by(status: "pending")
      return Result.new(:conflict, error: :case_busy, field_case: kase, turn: pending) if pending

      if @correlation_id.present? && FieldTurn.exists?(correlation_id: @correlation)
        return Result.new(:conflict, error: :correlation_taken)
      end

      Result.new(:conflict, error: :not_unique)
    end
  end
end
