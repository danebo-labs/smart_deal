# frozen_string_literal: true

require "test_helper"

# Ciclo 5 Fase 3 (H10, 2026-08-04): this script's PRIMARY finding is that the
# plan's single-line regex hypothesis for the N8 contamination is false (it
# matches only 1/96 contaminated bodies) — see docs/rag/plan_ciclo5_...md,
# Anexo H and "Decisión humana #10". The script therefore only ships a
# read-only diagnostic mode today; its real-write mode is an intentional
# `abort` gated by a decision that has not been made yet. Source-only
# assertions on purpose, matching the precedent of
# repair_seguridades_canonical_identity_and_acunaiento_test.rb: this script
# reads `tmp/seguridades_chunks_2026-07-28/` (gitignored, not guaranteed to
# exist in CI) and its own safety net calls `exit` on any anomaly — never
# `require`/`load` it from a test.
class RepairSeguridadesN8BodyTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("script/repair_seguridades_n8_body_2026-08-04.rb").read.freeze

  test "real-write mode is disabled and refuses to run even if confirmed" do
    assert_match(/ENV\["RAG_CHUNK_PATCH_CONFIRM"\] == "1"/, SOURCE)
    assert_match(/Modo real deshabilitado/, SOURCE)
  end

  test "makes no S3 or Bedrock calls in any code path (diagnostic-only today)" do
    assert_no_match(/Aws::S3::Client/, SOURCE)
    assert_no_match(/S3DocumentsService/, SOURCE)
    assert_no_match(/BulkKbSyncService/, SOURCE)
    assert_no_match(/start_ingestion_job/, SOURCE)
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
