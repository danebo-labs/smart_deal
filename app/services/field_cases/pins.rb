# frozen_string_literal: true

module FieldCases
  # Replaces the manuals of one case. A new case is not given another case's
  # pins. A pending turn keeps the set it was admitted with.
  class Pins
    def self.resolve(entries, account:)
      return [] if entries.empty?

      documents = KbDocument.where(id: entries.pluck("kb_document_id")).index_by(&:id)
      focus = entries.map do |entry|
        document = documents[entry["kb_document_id"]]
        return nil unless document&.document_uid == entry["document_uid"] &&
          Rag::KnowledgeScopePolicy.authorized?(document, viewer_account: account) &&
          ConversationSession.media_type_for(document) == "document"

        entry.merge("source_uri" => document.canonical_uri, "display_name" => document.display_name)
      end
      uris = focus.pluck("source_uri")
      return nil if uris.any?(&:blank?)
      return nil if Rag::KnowledgeScopePolicy.authorize_retrieval_set(uris, viewer_account: account).denied?

      focus
    end

    def self.change(account:, user:, field_case_id:, document_id:, document_uid: nil, remove: false, replace: false)
      new(account:, user:, field_case_id:, pins: nil).call do |entries|
        id = Integer(document_id, exception: false)
        kept = entries.reject { |entry| entry["kb_document_id"] == id }
        next kept if remove

        document = KbDocument.find_by(id:)
        next unless document && (document_uid.blank? || document.document_uid == document_uid)

        kept = [] if replace
        kept + [ { "kb_document_id" => id, "document_uid" => document.document_uid } ]
      end
    end

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

      kase = nil
      FieldCase.transaction do
        kase = Guard.locked_case(account: @account, user: @user, field_case_id: @field_case_id)
        return Result.new(:not_found) unless kase
        return Result.new(:conflict, error: :not_resumable, field_case: kase) unless kase.resumable?

        pending = kase.field_turns.find_by(status: "pending")
        return Result.new(:conflict, error: :case_busy, field_case: kase, turn: pending) if pending

        if block_given?
          requested = yield kase.document_focus.map { |entry| entry.slice(*Payload::PIN_KEYS) }
          return Result.new(:not_found) unless requested
        else
          requested = @pins
        end
        error, entries = Payload.pins(requested)
        return Result.new(:invalid, error:) if error
        return Result.new(:not_found) if block_given? && !self.class.resolve(entries, account: @account)

        # Locked row. The focus array was already checked; do not reload the owner.
        kase.update_columns(document_focus: entries, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end
      Result.new(:ok, field_case: kase.reload, payload: Presenter.case_hash(kase))
    end
  end
end
