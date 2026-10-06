# frozen_string_literal: true

require "test_helper"
require "ostruct"
require Rails.root.join("script/field_companion/f1_publication_capture")

class FieldCompanionF1PublicationCaptureTest < ActiveSupport::TestCase
  Capture = FieldCompanion::F1PublicationCapture
  MODEL = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
  SCHEMA = {
    type: "object",
    properties: {
      observations: { type: "array" },
      reference_fact: {
        type: %w[object null],
        properties: { citation: { type: "integer" }, evidence_span: { type: "string" } },
        required: %w[citation evidence_span]
      }
    },
    required: %w[observations]
  }.freeze
  ENVELOPE = {
    "observations" => [ "Mira la puerta." ],
    "reference_fact" => { "citation" => 1, "evidence_span" => "Q-731 = fallo de puerta." }
  }.freeze

  test "an accepted contract stores the envelope as raw and does not double count job tokens" do
    fields = Capture.case_fields(
      result: {
        answer: "Según el manual ZEPHYR QX-77, página 12 [1], Q-731 = fallo de puerta.",
        publication_mode: "unknown_identity_contract",
        publication_reference: "accepted",
        publication_rejected_fields: [],
        publication_fallback_reason: nil,
        diagnostics: { raw_answer: "rendered answer that must not become raw" }
      },
      converse_calls: [ observed_call ],
      query_prompts: [],
      query_texts: [],
      jobs: [ { input_tokens: 180, output_tokens: 40 } ]
    )

    assert_equal JSON.generate(ENVELOPE), fields[:raw]
    assert_not_equal fields[:raw], "rendered answer that must not become raw"
    assert_equal "unknown_identity_contract", fields[:publication_mode]
    assert_equal "accepted", fields[:publication_reference]
    assert fields[:contract_attempted]
    assert fields[:contract_accepted]
    assert_equal false, fields[:legacy_query_called]
    assert_equal "converse", fields[:generation_path]
    assert_equal "jobs", fields[:cost_basis]
    assert_equal 1, fields[:generation_count]
    assert_equal 180, fields[:input_tokens]
    assert_equal 40, fields[:output_tokens]
    assert_equal 180, fields[:converse_input_tokens]
    assert_equal MODEL, fields[:contract_model]
    assert_equal "unknown_identity_publication", fields[:contract_tool]
    assert_equal false, fields[:contract_has_current_job_actions]
    assert_equal %w[citation evidence_span], fields[:contract_reference_properties].sort
    assert_equal 1, fields[:contract_observation_count]
    assert fields[:contract_reference_requested]
    assert fields[:contract_reference_accepted]
    assert_includes fields[:contract_system], "unknown_identity_publication"
    assert_includes fields[:contract_user_prompt], "Q-731"
  end

  test "a fallback keeps the query raw and counts converse plus query once" do
    prose = "Envíalo al piso inferior, entra en inspección y corta tensión."
    fields = Capture.case_fields(
      result: {
        publication_mode: "unknown_identity_contract_fallback",
        publication_reference: nil,
        publication_rejected_fields: [],
        publication_fallback_reason: "unparsed",
        diagnostics: { raw_answer: prose }
      },
      converse_calls: [ observed_call.merge(envelope: nil, tool_name: nil, input_tokens: 90, output_tokens: 10) ],
      query_prompts: [ "legacy prompt identity_unknown_reference" ],
      query_texts: [ prose ],
      jobs: [ { input_tokens: 300, output_tokens: 80 } ]
    )

    assert_equal prose, fields[:raw]
    assert_equal "unparsed", fields[:publication_fallback_reason]
    assert_equal false, fields[:contract_accepted]
    assert fields[:contract_attempted]
    assert fields[:legacy_query_called]
    assert_equal "converse_plus_query", fields[:generation_path]
    assert_equal "jobs_plus_converse_usage", fields[:cost_basis]
    assert_equal 2, fields[:generation_count]
    assert_equal 390, fields[:input_tokens]
    assert_equal 90, fields[:output_tokens]
  end

  test "tracked converse and query jobs are not added twice" do
    fields = Capture.case_fields(
      result: { publication_mode: "unknown_identity_contract_fallback", diagnostics: { raw_answer: "prose" } },
      converse_calls: [ observed_call.merge(input_tokens: 90, output_tokens: 10) ],
      query_prompts: [ "legacy" ],
      query_texts: [ "prose" ],
      jobs: [ { input_tokens: 90, output_tokens: 10 }, { input_tokens: 300, output_tokens: 80 } ]
    )

    assert_equal "jobs", fields[:cost_basis]
    assert_equal 2, fields[:generation_count]
    assert_equal 390, fields[:input_tokens]
    assert_equal 90, fields[:output_tokens]
  end

  test "a transport failure with no usage is a reliable zero" do
    fields = Capture.case_fields(
      result: { diagnostics: { raw_answer: nil } },
      converse_calls: [ observed_call.merge(envelope: nil, tool_name: nil, input_tokens: 0, output_tokens: 0, transport_error: "Aws::BedrockRuntime::Errors::ServiceUnavailableException") ],
      query_prompts: [ "legacy prompt" ],
      query_texts: [ "" ],
      jobs: []
    )

    assert_equal "no_usage", fields[:cost_basis]
    assert_equal 0, fields[:input_tokens]
    assert_equal 0, fields[:generation_count]
    assert_equal "converse_plus_query", fields[:generation_path]
    assert_equal "Aws::BedrockRuntime::Errors::ServiceUnavailableException", fields[:contract_transport_error]
    assert_equal false, fields[:contract_accepted]
  end

  test "known identity does not look like a contract call" do
    fields = Capture.case_fields(
      result: { diagnostics: { raw_answer: "Revisar el sensor. [1]" }, answer: "Revisar el sensor. [1]" },
      converse_calls: [],
      query_prompts: [ "known prompt" ],
      query_texts: [ "Revisar el sensor. [1]" ],
      jobs: [ { input_tokens: 200, output_tokens: 20 } ]
    )

    assert_equal false, fields[:contract_attempted]
    assert_nil fields[:publication_mode]
    assert_equal "query", fields[:generation_path]
    assert_equal "Revisar el sensor. [1]", fields[:raw]
    assert_equal 200, fields[:input_tokens]
    assert_equal "jobs", fields[:cost_basis]
  end

  test "objective capture reads the generator-visible line and does not rebuild the prompt" do
    line = Rag::CompanionGuidanceContext::OBJECTIVE_LINES.fetch("advance_fault")
    prompt = "# FIELD COMPANION\n#{line}\nFollow that objective.\n\nQuestion: SENTINEL_PROMPT\nFollow-up: no."
    fields = Capture.annotate(
      prompt: prompt,
      question: "¿Es un Orona? ¿Cómo lo reseteo?",
      raw: "Mira si la puerta termina de cerrar.",
      published: "Mira si la puerta termina de cerrar.",
      guard_held: false,
      companion: {
        prompt: prompt,
        truncated: false,
        turn_objective: "advance_fault",
        turn_objective_basis: "default_fault_progress",
        reported_state_present: true
      }
    )

    assert_equal prompt, fields[:companion_prompt]
    assert_equal prompt.length, fields[:companion_prompt_chars]
    assert_equal false, fields[:companion_prompt_truncated]
    assert_equal "SENTINEL_PROMPT", fields.dig(:companion_sections, "question").delete_prefix("Question: ")
    assert_equal "advance_fault", fields[:turn_objective]
    assert_equal "default_fault_progress", fields[:turn_objective_basis]
    assert_equal true, fields[:reported_state_present]
    assert_equal true, fields[:objective_line_matches_context]
    assert_equal true, fields[:objective_followed]
    assert_equal Rag::CompanionGuidanceContext::COMPANION_POLICY_VERSION, fields[:companion_policy_version]
    assert_not_includes prompt, Rag::CompanionGuidanceContext::COMPANION_POLICY_VERSION
  end

  test "a no-state objective line is advance_fault and a missing snapshot is not rebuilt" do
    prompt = "# FIELD COMPANION\n#{Rag::CompanionGuidanceContext::NO_STATE_OBJECTIVE}\n"
    from_line = Capture.annotate(
      prompt: prompt,
      question: "Dame el procedimiento",
      raw: "Mira la puerta.",
      published: "Mira la puerta.",
      guard_held: false
    )

    assert_equal "advance_fault", from_line[:turn_objective]
    assert_nil from_line[:turn_objective_basis]
    assert_nil from_line[:reported_state_present]
    assert_nil from_line[:companion_prompt]
    assert_nil from_line[:objective_line_matches_context]
  end

  test "usefulness reason names a missing situation observation without changing the score" do
    assert_equal "useful", Capture.usefulness_reason("c01", "Observa si la puerta está abierta y si hay personas dentro.")
    assert_equal "missing_situation_observation", Capture.usefulness_reason("c01", "Describe la falla completa.")
    assert_equal "withheld", Capture.usefulness_reason("c01", "La identidad de este equipo no está confirmada.")
  end

  test "a prompt without the objective line does not invent one" do
    fields = Capture.annotate(
      prompt: "identity_unknown_reference",
      question: "¿Qué puedo mirar para identificar el equipo?",
      raw: "{}",
      published: "Según el manual.",
      guard_held: false
    )

    assert_nil fields[:turn_objective]
    assert_nil fields[:turn_objective_basis]
    assert_equal false, fields[:generation_policy_violation]
  end

  private

  def observed_call
    response = OpenStruct.new(
      output: OpenStruct.new(
        message: OpenStruct.new(
          content: [
            OpenStruct.new(
              tool_use: OpenStruct.new(name: "unknown_identity_publication", input: ENVELOPE)
            )
          ]
        )
      ),
      usage: OpenStruct.new(input_tokens: 180, output_tokens: 40)
    )
    params = {
      model_id: MODEL,
      system: [ { text: "You fill the unknown_identity_publication tool." } ],
      messages: [ { role: "user", content: [ { text: "Q-731 evidence" } ] } ],
      tool_config: {
        tools: [ { tool_spec: { name: "unknown_identity_publication", input_schema: { json: SCHEMA } } } ],
        tool_choice: { tool: { name: "unknown_identity_publication" } }
      }
    }
    Capture.observe(params, response)
  end
end
