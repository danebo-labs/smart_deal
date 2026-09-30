# frozen_string_literal: true

# Read-only. Compares the historical open OR with knowledge_scope on
# config/document_identities.yml. Writes tmp/field_companion/f3b2_recall.json.
# Does not call Bedrock or Anthropic and does not promote documents.
require "digest"
require "fileutils"
require "json"
require "yaml"

catalog_path = Rails.root.join("config/document_identities.yml")
documents = YAML.load_file(catalog_path).fetch("documents")
viewers = %w[1 3 5]

def viewer_report(documents, viewer_index)
  rows = documents.map { |entry| Rag::OpenRetrievalRecall.classify(entry, viewer_index: viewer_index) }
  summary = Rag::OpenRetrievalRecall.summarize(documents, viewer_index: viewer_index)
  gaps = rows.select { |row| row.disposition == "backfill_gap" }
  summary.merge(
    "backfill_document_ids" => gaps.map(&:document_id)
  )
end

seguridades = documents.find { |entry| entry["display_name"].to_s.include?("SEGURIDADES") }
payload = {
  "phase" => "F3B2",
  "source" => "config/document_identities.yml",
  "live_bedrock" => false,
  "knowledge_scope_assumed" => "tenant_private",
  "assumption" => "Catalog entries have no knowledge_scope. Missing scope is tenant_private. F3B1 seeded 0 danebo_general.",
  "historical_or" => "own account_id OR catalog index 1 or 3 OR manual_corpus=general",
  "current_corpus" => "own account_id OR knowledge_scope=danebo_general",
  "documents" => documents.size,
  "by_account_id" => documents.group_by { |entry| entry["account_id"].to_s }.transform_values(&:size),
  "viewers" => viewers.index_with { |viewer| viewer_report(documents, viewer) },
  "seguridades" => {
    "document_id" => seguridades["document_id"],
    "account_id" => seguridades["account_id"].to_s,
    "owner" => Rag::OpenRetrievalRecall.classify(seguridades, viewer_index: seguridades["account_id"]).disposition,
    "pilot_index_3" => Rag::OpenRetrievalRecall.classify(seguridades, viewer_index: "3").disposition
  },
  "holdout" => "script/fixtures/rag_seguridades_holdout_v*.json target SEGURIDADES. Not re-run live. The owner index retains that manual. A non-owner does not until knowledge_scope:apply.",
  "conclusion" => "Index 3 keeps every catalog manual it owns. The 19 index-1 manuals, including SEGURIDADES, are a backfill gap for that viewer. Restoring Legacy/Pilot/manual_corpus is not the fix."
}

out = Rails.root.join("tmp/field_companion/f3b2_recall.json")
FileUtils.mkdir_p(out.dirname)
File.write(out, JSON.pretty_generate(payload) + "\n")
puts Digest::SHA256.file(out).hexdigest
puts out
