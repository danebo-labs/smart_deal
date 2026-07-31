# frozen_string_literal: true

require "test_helper"
require "digest"

class BedrockGenerationPromptTest < ActiveSupport::TestCase
  PRE_CHANGE_SHA256 = "bed763f75b9adaad91d8bb535e7f33775b23c83b5d88c8fcc676cb689fb6c8da"

  def prompt
    @prompt ||= with_partial_contract("true") do
      BedrockRagService.load_generation_prompt_template
    end
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

  test "requires explicit connector pairs and documented LED logic" do
    assert_includes prompt, 'physical connection claim ("component → connector/terminal")'
    assert_includes prompt, "same evidence fragment explicitly names both endpoints as a pair"
    assert_includes prompt, "does not define its on/off logic"
    assert_match(
      /LED-label-only case, include DATA_NOT_AVAILABLE after the prose that identifies the missing on\/off logic/,
      prompt
    )
  end

  test "flag off restores the pre-change template sha256" do
    disabled_prompt = with_partial_contract(nil) do
      BedrockRagService.load_generation_prompt_template
    end

    assert_equal PRE_CHANGE_SHA256, Digest::SHA256.hexdigest(disabled_prompt)
    assert_not_includes disabled_prompt, BedrockRagService::PARTIAL_ABSTENTION_PROMPT_PREFIX
  end

  test "allows only the fixed safe glossary and forbids inferred device roles" do
    assert_includes prompt, "NO = normally"
    assert_includes prompt, "NC = normally"
    assert_includes prompt, "PTC ="
    assert_includes prompt, "NTC ="
    assert_includes prompt, "does not prove its operating role"
  end

  test "surfaces contradictions and blocks undocumented interventions" do
    assert_includes prompt, "leave the conflict unresolved"
    assert_includes prompt, "must not become an intervention procedure"
  end

  test "treats a heading that disagrees with its own table as a discrepancy" do
    assert_includes prompt, "when the conflict sits inside a single fragment"
    assert_includes prompt, "State both readings explicitly"
  end

  test "forbids transplanting a sibling board's wiring onto the model asked about" do
    assert_includes prompt, "use only evidence\n  about that model"
    assert_includes prompt, "is not evidence for the model asked about"
  end

  test "uses output_format_instructions as the single output contract" do
    assert_includes prompt, "$output_format_instructions$"
    # F1: the custom <DOC_REFS> block is retired — its XML parser collided with the
    # native citation format and returned canned "Sorry" responses.
    assert_not_includes prompt, "<DOC_REFS>"
    assert_not_includes prompt, "</DOC_REFS>"
    assert_not_includes prompt, "Reference rules:"
  end

  test "places output_format_instructions last as the sole trailing contract" do
    trimmed = prompt.rstrip
    assert trimmed.end_with?("$output_format_instructions$"),
           "output_format_instructions must be the final directive in the prompt"
  end

  test "keeps concise output rules" do
    assert_includes prompt, "at most three logical sections"
    assert_includes prompt, "No markdown tables"
    assert_includes prompt, "Do not add a generic safety closing"
  end

  private

  def with_partial_contract(value)
    original = ENV.fetch("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil)
    if value.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = original
    end
  end
end
