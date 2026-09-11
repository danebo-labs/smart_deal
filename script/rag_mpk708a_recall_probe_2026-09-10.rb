# frozen_string_literal: true

# Read-only. One-off probe for the auto-scope-retrieval plan: confirms the
# two MPK 708A KbDocuments in Gonzalo's piloto account actually have chunks
# in the KB before trusting the auto-scope fix to help question 1 of the
# 2026-09-11 brief. A single Retrieve call scoped to their source URIs — same
# pattern as script/rag_seguridades_recall_probe.rb. Dated/disposable: do not
# extend, see script/AGENTS.md.

require "json"

user = User.find_by(email: "gonzalo.campos@danebo.ai")
raise "user gonzalo.campos@danebo.ai not found" unless user

account = user.account
raise "user has no account" unless account

docs = KbDocument.where(account_id: account.id)
                 .where("display_name ILIKE ? OR aliases::text ILIKE ?", "%708A%", "%708A%")

payload = {
  measured_at: Time.current.utc.iso8601(6),
  account_id: account.id,
  question: "Que significa el codigo de error de la tarjeta MPK 708A y que reviso primero?",
  matched_kb_documents: docs.map { |d| { id: d.id, display_name: d.display_name, s3_key: d.s3_key, aliases: d.aliases } }
}

if docs.empty?
  payload[:error] = "no KbDocument matched %708A% for this account"
  puts JSON.pretty_generate(payload)
else
  uris = docs.map { |d| d.display_s3_uri(KbDocument::KB_BUCKET) }.compact
  service = BedrockRagService.new(account: account)
  retrieval = service.retrieve_chunks(
    payload[:question],
    entity_s3_uris: uris,
    entity_sources: [ "document" ],
    force_entity_filter: true,
    number_of_results: 8
  )
  chunks = retrieval[:chunks]

  payload[:scoped_source_uris] = uris
  payload[:chunks_returned] = chunks.size
  payload[:chunks] = chunks.map { |c|
    { rank: c[:rank], score: c[:score], source_uri: c[:bedrock_source_uri] || c[:original_source_uri],
      content_preview: c[:content].to_s.first(160) }
  }
  puts JSON.pretty_generate(payload)
end
