# frozen_string_literal: true

# Precomputes the deterministic document overview (table of contents) right
# after a technician pins a document, so the autofilled "what is this about"
# question is answered from cache/manifest instead of falling to the
# generative lane on the first ask.
class DocumentOverviewWarmJob < ApplicationJob
  queue_as :default
  # A warm miss is harmless: the request path falls back to the generative lane.
  retry_on StandardError, wait: 5.seconds, attempts: 1

  def perform(account_id:, kb_document_id:)
    account = Account.find_by(id: account_id)
    kb_doc  = account&.kb_documents&.find_by(id: kb_document_id)
    return unless kb_doc

    Rag::DocumentOverviewBuilder.call(account: account, kb_document: kb_doc, allow_cold_build: true)
  end
end
