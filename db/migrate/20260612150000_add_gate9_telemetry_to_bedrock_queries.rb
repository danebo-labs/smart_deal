# frozen_string_literal: true

# Gate 9R I0: one BedrockQuery row per billable invocation, with enough
# dimensions to rebuild expected/conservative/contractual cost scenarios
# without re-running anything:
#
#   route          — billing route ("sync" | "batch" | "bulk_retry" | "page_filter" |
#                    "rag_filtered" | "rag_global" | "query_direct")
#   attempt        — 1-based attempt within the same logical unit (page/photo/query);
#                    retries of the same unit increment it
#   max_tokens     — configured output cap for this invocation (ladder rung)
#   stop_reason    — raw provider stop reason ("end_turn" | "max_tokens" | "stop_sequence")
#   correlation_id — groups every attempt of one unit:
#                    "ingest:<sha12>"        whole file (photo/text/single-shot pdf)
#                    "ingest:<sha12>:p<N>"   one pdf page (prefix groups the document)
#                    "query:<uuid>"          one RAG turn (filtered + global fallback)
class AddGate9TelemetryToBedrockQueries < ActiveRecord::Migration[8.1]
  def change
    change_table :bedrock_queries, bulk: true do |t|
      t.string  :route
      t.integer :attempt
      t.integer :max_tokens
      t.string  :stop_reason
      t.string  :correlation_id
    end

    add_index :bedrock_queries, :correlation_id
  end
end
