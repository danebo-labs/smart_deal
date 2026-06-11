# frozen_string_literal: true

require "test_helper"

class BedrockGenerationPromptTest < ActiveSupport::TestCase
  def prompt
    @prompt ||= BedrockRagService.load_generation_prompt_template
  end

  test "treats retrieved chunks as evidence candidates" do
    assert_includes prompt, "evidence candidates, not automatically validated facts"
    assert_includes prompt, "Use only information explicitly stated"
    assert_not_includes prompt, "TRUST THE CHUNKS"
    assert_not_includes prompt, "already-validated content"
  end

  test "preserves documentary modality" do
    assert_includes prompt, '"may" is not "must"'
    assert_match(/"check" is\s+not "stop"/, prompt)
    assert_includes prompt, "a mentioned standard is not a mandatory certificate"
  end

  test "does not authorize inferred procedures or industry estimates" do
    assert_includes prompt, "only when explicitly documented"
    assert_includes prompt, "Do not rank probable causes without documentary support"
    assert_not_includes prompt, "approximate industry estimate"
    assert_not_includes prompt, "LOTO"
    assert_not_includes prompt, "estimated man-hours"
  end

  test "limits field verification to observed uncertainty" do
    assert_match(/identify the exact\s+uncertain datum as REQUIRES_FIELD_VERIFICATION/, prompt)
    assert_includes prompt, "never authorizes"
    assert_includes prompt, "PPE rule"
    assert_includes prompt, "stop condition"
  end

  test "requires explicit documentary stop conditions" do
    assert_includes prompt, "include only conditions"
    assert_includes prompt, "explicitly associates with stopping"
    assert_not_includes prompt, "If the site does not match the documentation, STOP"
  end

  test "keeps machine-readable references and concise output rules" do
    assert_includes prompt, "<DOC_REFS>"
    assert_includes prompt, "</DOC_REFS>"
    assert_includes prompt, "at most three logical sections"
    assert_includes prompt, "No markdown tables"
    assert_includes prompt, "Do not add a generic safety closing"
  end
end
