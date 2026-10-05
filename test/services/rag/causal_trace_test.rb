# frozen_string_literal: true

require "test_helper"

class Rag::CausalTraceTest < ActiveSupport::TestCase
  test "a span cut to the item limit is marked truncated" do
    token = Rag::CausalTrace.assertion_tokens(
      perception_for([ long_negate ]),
      decision_for("ready")
    ).sole

    assert_operator token.length, :<=, Rag::CausalTrace::ITEM_LIMIT
    assert token.end_with?(":truncated")
    assert_includes token, "negate:negate::ignored(no_slot):"
  end

  test "a slotless negate on a report is ignored and a slotted negate is applied" do
    tokens = Rag::CausalTrace.assertion_tokens(
      perception_for([
        identity("No veo ningún código de falla", "negate", nil),
        identity("E51", "negate", "fault_code")
      ]),
      decision_for("ready")
    )

    assert_equal "negate:negate::ignored(no_slot):No veo ningún código de falla", tokens[0]
    assert_equal "negate:negate:fault_code:applied:E51", tokens[1]
  end

  test "meta short-circuit wins over a missing slot" do
    token = Rag::CausalTrace.assertion_tokens(
      perception_for([ identity("No veo ningún código de falla", "negate", nil) ]),
      decision_for("meta")
    ).sole

    assert_includes token, "ignored(meta)"
    assert_not_includes token, "no_slot"
  end

  test "a photo block that is not split is mixed and guidance is counted from the prompt" do
    prompt = <<~TEXT
      # FIELD COMPANION
      Question: no nivela
      Known equipment identity: manufacturer Orona (photo)
      ## Photo Evidence (this turn)
      - Visible text/codes: X17
      Technician observations:
      - pasa solo en planta 3
      THIS JOB'S EQUIPMENT: Orona
      REFERENCE ONLY — OTHER EQUIPMENT: Monarch
      Reference-only manuals, names only: Yida; Fuji. Do not teach their contents.
    TEXT

    fields = Rag::CausalTrace.generation_fields(
      text: prompt, raw_turn: "No veo ningún código de falla", sent_question: "queda pasado de nivel", truncated: true
    )

    tokens = fields[:generation_context]
    assert_includes tokens, "technician_current_turn:absent"
    assert_includes tokens, "technician_facts_count:1"
    assert_includes tokens, "observations_count:1"
    assert_includes tokens, "photo_literal:mixed"
    assert_includes tokens, "photo_interpretation:mixed"
    assert_includes tokens, "compatible_docs_count:1"
    assert_includes tokens, "foreign_reference_docs_count:3"
    assert_includes tokens, "danebo_guidance:present"
    assert_equal prompt.length, fields[:generation_prompt_chars]
    assert_equal true, fields[:context_truncated]
  end

  test "managed success without an explicit mode is generative and a failure is not" do
    assert_equal "generative", Rag::CausalTrace.resolved_generation_mode(nil, success: true)
    assert_nil Rag::CausalTrace.resolved_generation_mode(nil, success: false)
    assert_equal "meta", Rag::CausalTrace.resolved_generation_mode("meta", success: true)
    assert_equal "document_identity_scope", Rag::CausalTrace.resolved_generation_mode("document_identity_scope", success: true)
  end

  private

  def long_negate
    identity("N" * 200, "negate", nil)
  end

  def identity(span, act, slot)
    Rag::TurnPerception::Identity.new(
      span: span, act: act, kind: act, slot: slot, value: span, source: nil, manufacturer: nil
    )
  end

  def perception_for(identities)
    Rag::TurnPerception::Result.new(
      valid: true, move: "report", observations: [], pending_resolution: nil, clarification_target: nil,
      identities: identities, ambiguities: [], field_rejections: [], catalog_disagreements: [], invalid_reason: nil
    )
  end

  def decision_for(name)
    Rag::RoutePolicy::Decision.new(
      decision: name, retrieval_query: nil, clarification: nil, pending_subject: nil,
      outside_discovery: false, owns_query: false, bare_identifier: nil, ask_when: nil,
      mutations: [], dialogue_function: "follow_up", context_carry: false, focus_uris: [],
      focus_document_ids: [], pending_question: nil, fallback: false
    )
  end
end
