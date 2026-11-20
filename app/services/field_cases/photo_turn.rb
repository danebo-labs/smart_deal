# frozen_string_literal: true

module FieldCases
  # A durable photo is written before admission. The submission key scopes
  # that object and its reading independently of identical bytes in other cases.
  class PhotoTurn < TextTurn
    def self.submit(account:, user:, field_case_id:, creation_key:, submission_id:, message:, image:, locale:, document_ids: [])
      refusal = Guard.gate(account:, user:)
      return refusal if refusal
      return Result.new(:invalid, error: :submission_id) unless Payload.key?(submission_id)
      return Result.new(:invalid, error: :message) if message.length > Payload::MESSAGE_MAX

      if field_case_id
        kase = FieldCase.find_by(id: field_case_id, account: account, user: user)
        return Result.new(:not_found) unless kase
      elsif !Payload.key?(creation_key)
        return Result.new(:invalid, error: :creation_key)
      end

      scope = Digest::SHA256.hexdigest([ user.id, kase ? "case:#{kase.id}" : "new:#{creation_key}", submission_id ].join("/"))
      photo = store_upload(account:, user:, image:, scope:)
      return Result.new(:invalid, error: :photo_storage) unless photo

      attributes = { account:, user:, client_submission_id: submission_id, message:, locale: }
      admission = if kase
        AdmitTurn.call(**attributes, field_case_id: kase.id, kind: "photo", field_photo_id: photo.id)
      else
        OpenText.call(**attributes, creation_key:, photo:, document_ids:)
      end
      return admission unless admission.created?

      enqueue(admission, account:, user:)
    end

    def self.retry(account:, user:, field_case_id:, turn_id:)
      refusal = Guard.gate(account:, user:)
      return refusal if refusal

      admission = FieldCase.transaction do
        kase = Guard.locked_case(account:, user:, field_case_id:)
        turn = kase&.field_turns&.find_by(id: turn_id, kind: "photo")
        next Result.new(:not_found) unless turn
        current = Result.new(:ok, field_case: kase, turn:)
        next current if turn.status == "completed" || (turn.status == "pending" && turn.lease_expires_at > Time.current)

        unless kase.resumable? && kase.last_sequence == turn.sequence && owned_photo?(turn, kase)
          next Result.new(:conflict, error: :photo_retry_unavailable)
        end

        turn.update!(
          status: "pending", phase: "queued", attempt: turn.attempt + 1,
          execution_token: SecureRandom.uuid, base_state_revision: kase.state_revision,
          lease_expires_at: Time.current + AdmitTurn::LEASE, completed_at: nil,
          failure_code: nil, failure_stage: nil, response: nil, result_state_revision: nil
        )
        Result.new(:ok, field_case: kase, turn:, created: true)
      end
      admission.created? ? enqueue(admission, account:, user:) : admission
    end

    def self.claim(field_case_id:, field_turn_id:, account_id:, user_id:, execution_token:)
      FieldCase.transaction do
        kase = FieldCase.lock.find_by(id: field_case_id, account_id:, user_id:)
        next unless kase && Guard.gate(account: kase.account, user: kase.user).nil?

        turn = kase.field_turns.find_by(id: field_turn_id, kind: "photo", status: "pending",
                                       phase: "queued", execution_token:)
        next unless turn && owned_photo?(turn, kase) && turn.base_state_revision == kase.state_revision

        turn.update!(phase: "vision", lease_expires_at: Time.current + AdmitTurn::LEASE)
        new(Result.new(:ok, field_case: kase, turn:), account: kase.account, user: kase.user)
      end
    end

    def self.owned_photo?(turn, kase)
      photo = turn.field_photo
      photo && photo.account_id == kase.account_id && photo.user_id == kase.user_id && photo.storage_scope.present?
    end

    def self.store_upload(account:, user:, image:, scope:)
      binary = image.fetch(:binary)
      FieldPhotoStore.persist!(
        account_id: account.id, user_id: user.id, storage_scope: scope,
        sha256: Digest::SHA256.hexdigest(binary), binary:,
        content_type: image.fetch(:media_type), filename: File.basename(image[:filename].presence || "photo"),
        **image.slice(:thumbnail_binary, :thumbnail_content_type, :thumbnail_width, :thumbnail_height)
      )
    rescue StandardError => error
      Rails.logger.warn("Case photo storage failed: #{error.class}")
      nil
    end

    def self.enqueue(admission, account:, user:)
      turn = admission.turn
      Rag::ValidationCapture.bind(field_case_id: turn.field_case_id, field_turn_id: turn.id)
      Rag::ValidationCapture.correlation = turn.correlation_id if Rag::ValidationCapture.active?
      job = FieldPhotoAnalysisJob.perform_later(
        field_case_id: turn.field_case_id, field_turn_id: turn.id, execution_token: turn.execution_token,
        account_id: account.id, user_id: user.id
      )
      return admission if job

      new(admission, account:, user:).fail("enqueue_failed")
    rescue StandardError => error
      Rails.logger.warn("Case photo enqueue failed: #{error.class}")
      new(admission, account:, user:).fail("enqueue_failed")
    end

    attr_reader :turn

    def with_running_turn
      FieldCase.transaction do
        kase = Guard.locked_case(account: @account, user: @user, field_case_id: @case.id)
        next unless kase&.state_revision == turn.base_state_revision
        next unless kase.field_turns.exists?(id: turn.id, status: "pending", execution_token: turn.execution_token)

        yield
      end
    end

    def publish(answer:, citations:, provenance:, context:, visual_summary: nil, pending_question: nil)
      if context.respond_to?(:install_published_pending!)
        context.install_published_pending!(pending_question, correlation_id: turn.correlation_id)
      end
      complete(
        { answer:, citations: Array(citations), provenance_segments: Array(provenance),
          response_locale: turn.locale, visual_summary: }.compact,
        context,
        prompt_reply: answer
      )
    end

    def fail(code)
      message = I18n.with_locale(turn.locale.presence || I18n.default_locale) { I18n.t("rag.photo_analysis_failed") }
      close(
        outcome: "failed", failure_code: code, failure_stage: "photo",
        response: { render: { status: "error", message: message } }
      )
    end
  end
end
