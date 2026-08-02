# frozen_string_literal: true

# Fase 5 / I-37 (docs/rag/plan_conocimiento_visual.md): carries a page's derived
# topology edges across the Anthropic Batch API round trip.
#
# `page_customs` already proves this row is the durable transport between
# SubmitManualBatchJob and IngestManualBatchResultsJob — the job reads the whole
# context back from here hours later. The edges ride the same way, keyed by page
# number exactly like `page_customs`, because by the time the batch result is
# parsed `page.cleanup` has run and there is no binary left to re-derive from.
#
# Shape: { "3" => [ { "from" => …, "to" => …, "method" => "leader_line"|"vision",
#                     "evidence" => … } ] }
#
# Empty for every row written with both ingestion flags off, which is the default.
class AddPageTopologyEdgesToWebManualBatches < ActiveRecord::Migration[8.1]
  def change
    add_column :web_manual_batches, :page_topology_edges, :jsonb, default: {}, null: false
  end
end
