# frozen_string_literal: true

require "test_helper"

class BatchChunkingPromptTest < ActiveSupport::TestCase
  def prompt
    @prompt ||= BatchChunkingPrompt::SYSTEM_BLOCKS.first.fetch(:text)
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
end
