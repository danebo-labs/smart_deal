# frozen_string_literal: true

require "test_helper"

# Ciclo 5 Fase 3 (H10, 2026-08-04): this script's PRIMARY finding is that the
# plan's single-line regex hypothesis for the N8 contamination is false (it
# matches only 1/96 contaminated bodies) — see docs/rag/plan_ciclo5_...md,
# Anexo H and "Decisión humana #10". The owner resolved #10 authorizing full
# block removal (Alcance A), so the script now ships a real-write mode gated
# behind RAG_CHUNK_PATCH_CONFIRM=1. Source-only assertions on purpose,
# matching the precedent of
# repair_seguridades_canonical_identity_and_acunaiento_test.rb: this script
# reads `tmp/seguridades_chunks_2026-07-28/` (gitignored, not guaranteed to
# exist in CI), talks to live AWS in real mode, and its own safety net calls
# `exit` on any anomaly — never `require`/`load` it from a test.
class RepairSeguridadesN8BodyTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("script/repair_seguridades_n8_body_2026-08-04.rb").read.freeze

  test "diagnostic mode is the default and real mode requires an explicit confirm env var" do
    assert_match(/REAL_MODE = ENV\["RAG_CHUNK_PATCH_CONFIRM"\] == "1"/, SOURCE)
    assert_match(/exit 0 unless REAL_MODE/, SOURCE)
  end

  test "real mode reads live S3 bodies instead of trusting the local reference copy for content" do
    # H10 follow-up (2026-08-04): the first real-run attempt pre-verified ETag
    # against the 2026-07-28 local reference and aborted on drift (chunk_23).
    # Fixed by always downloading fresh in real mode and analyzing that body.
    assert_match(/live = s3\.download\("#\{CHUNK_PREFIX\}\/#\{name\}"\)/, SOURCE)
    assert_match(/REAL_MODE \? s3\.download|body = if REAL_MODE/, SOURCE)
  end

  test "real mode backs up every live body to S3 and local tmp before writing" do
    assert_match(/backup_prefix = "chunk_body_backups/, SOURCE)
    assert_match(/s3\.upload_binary\("#\{backup_prefix\}\/#\{r\[:file\]\}"/, SOURCE)
  end

  test "real mode writes patched bodies in place and triggers a KB resync poll" do
    assert_match(/s3\.upload_text\(key, r\[:new_body\]\)/, SOURCE)
    assert_match(/BulkKbSyncService\.new\.sync!/, SOURCE)
    assert_match(/status == "COMPLETE"/, SOURCE)
  end

  test "documents the falsified single-line hypothesis and the block-detection replacement" do
    assert_match(/FALSIFICADA/, SOURCE)
    assert_match(/PLAN_LITERAL_REGEX/, SOURCE)
    assert_match(/BLOCK_CONTINUATION/, SOURCE)
  end

  test "encodes both known stray-contamination special cases with their exact verbatim text" do
    assert_match(/"chunk_0\.txt" => \[/, SOURCE)
    assert_match(/ORIGINAL_FILE_NAME \| PIPELINE_INJECTED/, SOURCE)
    assert_match(/"chunk_36\.txt" => \[/, SOURCE)
    assert_match(/Sistema general: ALJO Control Level 1B Altius/, SOURCE)
  end

  test "aborts rather than proposing a removal that would leave residual contamination" do
    assert_match(/queda contaminaci.n residual tras la remoci.n propuesta/, SOURCE)
  end

  test "never treats chunk_90 (the one already-clean divider) as contaminated" do
    assert_match(/chunk_90 case/, SOURCE)
  end
end
