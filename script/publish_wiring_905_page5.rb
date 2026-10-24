# frozen_string_literal: true

# Effects: replaces Wiring - 905 chunk_p5_1.txt, creates chunk_p5_2.txt and
# chunk_p5_3.txt with the shared sidecar, and starts one ingestion job on
# Y7RZWMFJSR / PJ0N58DMHG. Restores only those keys if the write, the object
# check, or indexing of these fragments fails.
#
# WIRING905_RESUME_DIR=<evidence> bin/rails runner script/publish_wiring_905_page5.rb
# reanuda la sincronización de una subida ya verificada, sin reescribir objetos.

evidence = ENV["WIRING905_RESUME_DIR"].presence
report =
  if evidence
    Wiring905Page5Publication.resume!(evidence_dir: evidence)
  else
    Wiring905Page5Publication.call
  end
summary = report.except("inventory_before", "inventory_after", "job_polls", "idle_checks")
File.write(File.join(report.fetch("evidence_dir"), "summary.json"), JSON.generate(summary))
puts JSON.generate(report.slice(
  "verdict", "resume", "previous_stop", "backup", "uploaded", "published_sha256",
  "resume_verified_sha256", "sidecar_review", "sync_result", "resync_result",
  "foreign_failures", "aurora_retries", "cache_invalidated", "stopped",
  "restore_stopped", "size_error_resolved", "restored_state", "prefix_count_before",
  "prefix_count_after", "unchanged_key_count", "data_source", "embedding_model_arn",
  "start_requests", "start_adopted"
))
