# frozen_string_literal: true

require "test_helper"

class BatchChunkingPromptTest < ActiveSupport::TestCase
  def prompt
    @prompt ||= BatchChunkingPrompt::SYSTEM_BLOCKS.first.fetch(:text)
  end

  test "declares a contract version and a stable prompt fingerprint" do
    assert_equal "field_records_v3", BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
    assert_match(/\A[0-9a-f]{64}\z/, BatchChunkingPrompt.prompt_fingerprint_sha256)
    assert_equal BatchChunkingPrompt.prompt_fingerprint_sha256,
                 Digest::SHA256.hexdigest(BatchChunkingPrompt::SYSTEM_BLOCKS.pluck(:text).join("\n"))
  end

  test "preserves mid-section page continuations" do
    assert_includes prompt, "PAGE CONTINUATION"
    assert_includes prompt, "NEVER drop that content"
    assert_includes prompt, "(continuación de página anterior)"

    instruction = BatchChunkingPrompt.page_user_content(
      binary: "%PDF-fake", page_number: 10, total_pages: 24, filename: "m.pdf"
    ).last.fetch(:text)
    assert_includes instruction, "begins mid-section"
    assert_includes instruction, "never drop it"
  end

  test "types test-section steps as FUNCTIONAL_TEST and forbids restated results" do
    assert_includes prompt, "INSIDE a functional-test section"
    assert_includes prompt, "k=FUNCTIONAL_TEST"
    assert_includes prompt, "NEVER restate the action's intent as its result"
  end

  test "preserves source modality and action verbs" do
    assert_includes prompt, "Preserve the source's exact modality and action verbs"
    assert_includes prompt, '"Check", "avoid"'
    assert_includes prompt, '"may", and "must" are not interchangeable'
  end

  test "does not infer PPE certificates or stop conditions" do
    assert_includes prompt, "Do not add PPE, helmets, harnesses, certificates"
    assert_match(/unless the visible source\s+explicitly requires them/, prompt)
    assert_includes prompt, "A standard mentioned by the source is informational"
  end

  test "uses field verification only for observed uncertainty" do
    assert_includes prompt, "illegible text or images"
    assert_includes prompt, "ambiguous value or identity"
    assert_includes prompt, "partial input"
    assert_includes prompt, "truncated output"
    assert_includes prompt, "never authorizes creating an action"
  end

  test "requests atomic field records without model-generated identifiers" do
    assert_includes prompt, '"field_records"'
    assert_includes prompt, "# FIELD-SAFETY EVIDENCE RECORDS"
    assert_includes prompt, "independently verifiable record per result"
    assert_includes prompt, "Omit absent optional keys and record IDs. Rails creates IDs"
    assert_includes prompt, "Never merge opposing states or separate results"
  end

  test "requires explicit paired stop-work evidence" do
    assert_includes prompt, "STOP_WORK_CONDITION requires both sw elements"
    assert_includes prompt, "from the same visible fragment"
    assert_includes prompt, "otherwise use another type"
  end

  test "keeps records with their semantic chunk" do
    assert_includes prompt, "Records belong in the same semantic chunk"
    assert_includes prompt, "Do not create a separate one-sentence chunk"
    assert_includes prompt, "more than 8 records"
  end

  test "uses compact output keys and omits unavailable optional details" do
    assert_includes prompt, '"k": "<record type>"'
    assert_includes prompt, '"ev": "<short exact supporting phrase>"'
    assert_includes prompt, "Omit absent optional keys"
    assert_not_includes prompt, '"preconditions":'
    assert_not_includes prompt, '"measurements_or_limits":'
  end
end
