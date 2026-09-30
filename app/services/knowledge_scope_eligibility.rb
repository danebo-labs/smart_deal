# frozen_string_literal: true

# Write guard for tenant_private → danebo_general.
# Read access does not call this. kb_documents.knowledge_scope stays the authority.
#
# accounts has no internal-ownership flag. Slug, branded, and the Legacy/Pilot
# retrieve OR are historical context, not a source-account decision. The
# explicit mark is accounts.danebo_controlled, default false.
class KnowledgeScopeEligibility
  class Denied < StandardError
    attr_reader :reasons

    def initialize(reasons)
      @reasons = Array(reasons).freeze
      super(@reasons.join(", "))
    end
  end

  PHOTO_INGESTION_PATH = Rag::SharedManualCorpus::PHOTO_INGESTION_PATH

  class << self
    def blocking_reasons(document)
      reasons = []
      unless document.is_a?(KbDocument) && document.persisted?
        return [ "not_persisted" ]
      end

      reasons << "missing_account" if document.account_id.blank?
      reasons << "missing_document_uid" if document.document_uid.blank?
      reasons << "missing_s3_key" if document.s3_key.blank?
      reasons << "account_not_danebo_controlled" unless document.account&.danebo_controlled?
      reasons << "field_photo" if field_photo?(document)
      reasons << "ambiguous_document_uid" if document.document_uid.present? && ambiguous_uid?(document)
      reasons << "ambiguous_s3_key" if document.s3_key.present? && ambiguous_key?(document)
      reasons << "not_indexed" unless indexed_for_retrieval?(document)
      reasons
    end

    def field_photo?(document)
      key = KbDocument.object_key_for_match(document.s3_key).to_s
      return true if key == FieldPhotoStore::PREFIX || key.start_with?("#{FieldPhotoStore::PREFIX}/")

      BulkUploadAsset.exists?(kb_document_id: document.id, ingestion_path: PHOTO_INGESTION_PATH)
    end

    # Affirmative retrieval evidence: a completed non-photo ingestion ledger
    # that wrote chunks_s3_prefix. A KbDocument with no ledger is not indexed.
    # Historical rows stay tenant_private until that ledger exists. Filename,
    # slug, and the row itself are not this signal.
    def indexed_for_retrieval?(document)
      assets = BulkUploadAsset.where(kb_document_id: document.id)
      batches = WebManualBatch.where(kb_document_id: document.id)
      completed_manual?(assets, batches)
    end

    private

    def completed_manual?(assets, batches)
      assets.where(status: "complete")
        .where.not(ingestion_path: PHOTO_INGESTION_PATH)
        .where.not(chunks_s3_prefix: [ nil, "" ])
        .exists? ||
        batches.where(status: "complete").where.not(chunks_s3_prefix: [ nil, "" ]).exists?
    end

    def ambiguous_uid?(document)
      KbDocument.where(document_uid: document.document_uid).where.not(id: document.id).exists?
    end

    def ambiguous_key?(document)
      source = document.canonical_source
      return true if source.nil?

      bucket, key = source
      KbDocument.where(s3_key: [ key, "s3://#{bucket}/#{key}" ]).where.not(id: document.id).any? do |row|
        row.canonical_source == source
      end
    end
  end
end
