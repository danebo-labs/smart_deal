# frozen_string_literal: true

require "test_helper"

class BatchChunkingPromptTest < ActiveSupport::TestCase
  def prompt
    @prompt ||= BatchChunkingPrompt::SYSTEM_BLOCKS.first.fetch(:text)
  end

  test "declares a contract version and a stable prompt fingerprint" do
    assert_equal "field_records_v4", BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
    assert_match(/\A[0-9a-f]{64}\z/, BatchChunkingPrompt.prompt_fingerprint_sha256)
    assert_equal BatchChunkingPrompt.prompt_fingerprint_sha256,
                 Digest::SHA256.hexdigest(BatchChunkingPrompt::SYSTEM_BLOCKS.pluck(:text).join("\n"))
  end

  test "system prompt declares PAGE ROLE section with ANCHOR/CONTENT rules" do
    assert_includes prompt, "PAGE ROLE"
    assert_includes prompt, "ANCHOR_PAGE"
    assert_includes prompt, "CONTENT_PAGE"
    assert_includes prompt, "ANCHOR_PAGE only for multi-page parses"
  end

  test "S0 chunks[0] rule is scoped to no-tag or ANCHOR_PAGE and excludes CONTENT_PAGE" do
    assert_includes prompt, "chunks[0].text MUST contain the S0 — DOCUMENT IDENTIFICATION section"
    assert_match(/ONLY when there is no "Page role:" tag.*ANCHOR_PAGE/m, prompt)
    assert_match(/When the tag is CONTENT_PAGE, omit S0 entirely/, prompt)
  end

  test "system prompt ties summary/companion_offer exceptions to CONTENT_PAGE role" do
    assert_includes prompt, "Exception for per-page parses: CONTENT_PAGE role omits summary"
    assert_includes prompt, "Exception for per-page parses: CONTENT_PAGE role omits companion_offer"
  end

  test "anchor page instruction injects ANCHOR_PAGE role tag" do
    instruction = BatchChunkingPrompt.page_user_content(
      binary: "%PDF-fake", page_number: 1, total_pages: 5, filename: "m.pdf", anchor: true
    ).last.fetch(:text)
    assert_includes instruction, "Page role: ANCHOR_PAGE"
    assert_not_includes instruction, "Page role: CONTENT_PAGE"
  end

  test "content page instruction injects CONTENT_PAGE role tag" do
    instruction = BatchChunkingPrompt.page_user_content(
      binary: "%PDF-fake", page_number: 3, total_pages: 5, filename: "m.pdf", anchor: false
    ).last.fetch(:text)
    assert_includes instruction, "Page role: CONTENT_PAGE"
    assert_not_includes instruction, "Page role: ANCHOR_PAGE"
  end

  test "page_user_content defaults to CONTENT_PAGE when anchor not specified" do
    instruction = BatchChunkingPrompt.page_user_content(
      binary: "%PDF-fake", page_number: 10, total_pages: 24, filename: "m.pdf"
    ).last.fetch(:text)
    assert_includes instruction, "Page role: CONTENT_PAGE"
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

  test "system prompt enforces exact document_name match when Document name hint is present" do
    assert_includes prompt, "Document name hint: <name>"
    assert_match(/document_name.*MUST equal exactly.*<name>/m, prompt)
    assert_includes prompt, "no reformatting, no\ncreative rewriting"
    assert_match(/applies to all page roles.*CONTENT_PAGE/m, prompt)
  end

  test "system prompt rejects page-specific document_name for CONTENT_PAGE without hint" do
    assert_match(/When no `Document name hint:` is present.*whole-file manual\n\s+identity/m, prompt)
    assert_includes prompt, "do NOT use chapter, section, page heading"
    assert_match(/page-specific topic titles as the\s+document name/m, prompt)
  end

  test "page_user_content includes document_name_hint verbatim in user instruction" do
    hint = "Manual Plataforma Tijera Operación Controles"
    instruction = BatchChunkingPrompt.page_user_content(
      binary: "%PDF-fake", page_number: 3, total_pages: 5, filename: "m.pdf",
      document_name_hint: hint, anchor: false
    ).last.fetch(:text)
    assert_includes instruction, "Document name hint: #{hint}"
    assert_includes instruction, "Page role: CONTENT_PAGE"
  end

  test "page_user_content omits document_name_hint line when hint is nil" do
    instruction = BatchChunkingPrompt.page_user_content(
      binary: "%PDF-fake", page_number: 2, total_pages: 5, filename: "m.pdf",
      document_name_hint: nil, anchor: false
    ).last.fetch(:text)
    assert_not_includes instruction, "Document name hint:"
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
    assert_includes prompt, "Never emit a field_record without ev"
    assert_includes prompt, "Never merge opposing states or separate results"
  end

  test "requires explicit paired stop-work evidence" do
    assert_includes prompt, "STOP_WORK_CONDITION requires both sw elements"
    assert_includes prompt, "from the same visible fragment"
    assert_includes prompt, "otherwise use another type"
    assert_includes prompt, "Conditional operating-limit statements are STOP_WORK_CONDITION"
    assert_includes prompt, "exceeding the limit requires lifting"
    assert_includes prompt, "non-driving recovery method"
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
