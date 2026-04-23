# frozen_string_literal: true

# Pagination + field helpers for `bin/rails kb:documents` (ListKnowledgeBaseDocuments).
module KbDocumentsRakeHelper
  module_function

  def collect_document_details(client, kb_id, ds_id)
    details = []
    token = nil
    loop do
      resp = client.list_knowledge_base_documents(
        knowledge_base_id: kb_id,
        data_source_id: ds_id,
        max_results: 1000,
        next_token: token
      )
      details.concat(resp.document_details.to_a)
      token = resp.next_token
      break if token.blank?
    end
    details
  end

  def s3_uri_from_detail(detail)
    detail&.identifier&.s3&.uri
  end

  def detail_as_hash(detail)
    id = detail.identifier
    {
      status: detail.status,
      updated_at: detail.updated_at&.iso8601,
      status_reason: detail.status_reason,
      uri: s3_uri_from_detail(detail),
      custom_id: id&.custom&.id,
      data_source_type: id&.data_source_type
    }.compact
  end
end
