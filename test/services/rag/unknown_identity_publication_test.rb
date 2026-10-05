# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Rag::UnknownIdentityPublicationTest < ActiveSupport::TestCase
  QUESTION = "El display muestra Q-731, ¿qué significa?"
  REFUSAL = "I can't give you a procedure to bring the car down"
  FACT = "Q-731 = fallo de puerta"
  PARAPHRASE = "Q-731 aparece como fallo de puerta"
  SAFE_OBSERVATION = "Mira la posición de la cabina y si las puertas están abiertas."

  test "the schema has no current-job action field" do
    properties = Rag::UnknownIdentityPublication.tool_schema[:properties]

    assert_equal %w[observations nameplate_question reference_fact], properties.keys.map(&:to_s)
    assert_not_includes properties.keys.map(&:to_s), "current_job_actions"
  end

  test "a qualified code reference survives and the rendered prose passes the guard" do
    rendered = compose(qualified_envelope).answer
    distant = "#{reference_sentence}\n\nEsto no está confirmado para el equipo que tienes delante."

    assert_includes rendered, reference_sentence
    assert_includes rendered, "Esto no está confirmado para el equipo que tienes delante."
    assert_includes rendered, "[1]"
    assert_includes rendered, SAFE_OBSERVATION
    assert_not_includes rendered, "La identidad de este equipo no está confirmada."
    assert_nil guard(rendered)
    assert guard(distant)
    assert guard(rendered, envelope_json(qualified_envelope(REFUSAL)))
  end

  test "a refusal that names an operation is dropped instead of withholding the answer" do
    result = compose(qualified_envelope(REFUSAL, observation: nil))

    assert_includes result.rejected_fields, "observations[0]"
    assert_equal "accepted", result.reference_status
    assert_not_includes result.answer, "bring the car"
    assert_nil guard(result.answer)
  end

  test "attribution does not depend on where the model would have placed the disclaimer" do
    result = compose(
      "observations" => [ SAFE_OBSERVATION ],
      "reference_fact" => { "citation" => 1, "fact" => FACT }
    )

    assert_equal "accepted", result.reference_status
    assert_includes result.answer, reference_sentence
    assert_includes result.answer, "Esto no está confirmado para el equipo que tienes delante."
    assert_nil guard(result.answer)
  end

  test "an operation, a measured value, and a setting are dropped" do
    result = compose(
      "observations" => [ "Cortar tensión en el borne XQ7.", SAFE_OBSERVATION ],
      "reference_fact" => { "citation" => 1, "fact" => "Esperar 47 s." },
      "current_job_actions" => [ "Ajustar el parámetro." ]
    )

    assert_includes result.rejected_fields, "observations[0]"
    assert_includes result.rejected_fields, "reference_fact"
    assert_includes result.rejected_fields, "current_job_actions"
    assert_includes result.answer, SAFE_OBSERVATION
    assert_not_includes result.answer, "XQ7"
    assert_not_includes result.answer, "47"
    assert_not_includes result.answer, "Ajustar"
    assert_equal "rejected", result.reference_status
    assert_nil guard(result.answer)
  end

  test "a safe observation survives beside a rejected reference" do
    result = compose(
      "observations" => [ SAFE_OBSERVATION, REFUSAL ],
      "reference_fact" => { "citation" => 1, "fact" => "Cortar tensión en el borne XQ7." }
    )

    assert_includes result.answer, SAFE_OBSERVATION
    assert_not_includes result.answer, "bring the car"
    assert_not_includes result.answer, "XQ7"
    assert_equal "rejected", result.reference_status
    assert_nil guard(result.answer)
  end

  test "citation provenance is the evidence number, not a substring of the fact" do
    missing = compose(
      "observations" => [ SAFE_OBSERVATION ],
      "reference_fact" => { "citation" => 4, "fact" => FACT }
    )
    paraphrased = compose(
      "observations" => [ SAFE_OBSERVATION ],
      "reference_fact" => { "citation" => 1, "fact" => PARAPHRASE }
    )

    assert_equal "rejected", missing.reference_status
    assert_not_includes missing.answer, "fallo de puerta"
    assert_equal "accepted", paraphrased.reference_status
    assert_includes paraphrased.answer, "Según el manual ZEPHYR QX-77, página 12 [1], #{PARAPHRASE}."
    assert_not zephyr_chunk[:content].include?(PARAPHRASE)
  end

  test "a malformed envelope falls back instead of rendering" do
    [ nil, "prose", { "observations" => "Mira la puerta." } ].each do |envelope|
      result = Rag::UnknownIdentityPublication.compose(envelope, chunks: [ zephyr_chunk ], question: QUESTION, locale: :es)

      assert_equal "unknown_identity_contract_fallback", result.mode, envelope.inspect
      assert_equal "malformed", result.fallback_reason
      assert_nil result.answer
    end
  end

  test "english rendering passes the guard" do
    result = Rag::UnknownIdentityPublication.compose(
      qualified_envelope, chunks: [ zephyr_chunk ], question: QUESTION, locale: :en
    )

    assert_includes result.answer, "According to the manual ZEPHYR QX-77, page 12 [1], #{FACT}."
    assert_includes result.answer, "This is not confirmed for the equipment in front of you."
    assert_nil Rag::DocumentIdentityScope.unconfirmed_applicability_violation(result.answer, nil, [ zephyr_chunk ], QUESTION)
  end

  test "the tool request stays on the production Haiku model" do
    generator = RecordingGenerator.new(qualified_envelope)
    result = Rag::UnknownIdentityPublication.generate(
      client: generator, question: QUESTION, chunks: [ zephyr_chunk ], locale: :es
    )

    assert result.accepted?
    assert_equal BedrockClient::QUERY_MODEL_ID, generator.converse_calls.sole[:model_id]
    assert_includes BedrockClient::QUERY_MODEL_ID, "claude-haiku-4-5"
    assert_equal 0, generator.converse_calls.sole.dig(:inference_config, :temperature)
    assert_nil generator.converse_calls.sole.dig(:tool_config, :tools, 0, :tool_spec, :input_schema, :json, :properties, :current_job_actions)
  end

  test "managed and structured unknown lanes render the same qualified reference" do
    managed = run_managed(qualified_envelope(REFUSAL))
    structured = run_structured(qualified_envelope(REFUSAL))

    [ managed, structured ].each do |result|
      assert_equal "unknown_identity_contract", result[:publication_mode]
      assert_equal "accepted", result[:publication_reference]
      assert_includes result[:publication_rejected_fields], "observations[1]"
      assert_includes result[:answer], reference_sentence
      assert_includes result[:answer], "Esto no está confirmado para el equipo que tienes delante."
      assert_includes result[:answer], SAFE_OBSERVATION
      assert_not_includes result[:answer], "bring the car"
      assert_not_includes result[:answer], "La identidad de este equipo no está confirmada."
      assert_nil result[:applicability_violation]
      assert result[:citations].any?
      assert_nil guard(result[:answer])
    end
    assert_equal 0, managed[:query_calls]
    assert_equal 0, structured[:query_calls]
  end

  test "a failed contract falls back to the prose guard" do
    prose = "Envíalo al piso inferior, entra en inspección y corta tensión."
    managed = run_managed({ "observations" => "not-an-envelope" }, prose: prose)

    assert_equal "unknown_identity_contract_fallback", managed[:publication_mode]
    assert_equal "malformed", managed[:publication_fallback_reason]
    assert_equal 1, managed[:query_calls]
    assert_equal :procedure_application, managed[:applicability_violation]
    assert_includes managed[:answer], "La identidad de este equipo no está confirmada."
    assert_not_includes managed[:answer], "Envíalo"
  end

  test "known identity does not use the publication contract" do
    generator = RecordingGenerator.new(qualified_envelope, prose: "Revisar el sensor de nivelación. [1]")
    chunk = {
      content: "En PBCM-V3 revisar el sensor de nivelación.",
      metadata: { "canonical_name" => "Manual Orona PBCM-V3", "page_number" => 4, "section_identity" => "ORONA PBCM-V3" },
      location_uri: "s3://bucket/orona.pdf"
    }
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: [ chunk ], retrieval_trace: {} } }
    service.define_singleton_method(:document_identity_generator) { generator }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| flunk "open rag" }

    result = with_identity_flag do
      service.query("no nivela", equipment_identity: orona_identity, output_channel: :web, response_locale: :es)
    end

    assert_equal 0, generator.converse_calls.size
    assert_equal 1, generator.query_calls.size
    assert_equal "Revisar el sensor de nivelación. [1]", result[:answer]
    assert_nil result[:publication_mode]
    assert_nil result[:applicability_violation]
  end

  test "known structured identity does not call the publication tool" do
    generator = RecordingGenerator.new(qualified_envelope, prose: "Revisar el sensor de nivelación. [1]")
    chunk = zephyr_chunk.merge(
      content: "En PBCM-V3 revisar el sensor de nivelación.",
      metadata: {
        "canonical_name" => "Manual Orona PBCM-V3",
        "page_number" => 4,
        "section_identity" => "ORONA PBCM-V3",
        "original_source_uri" => "s3://bucket/zephyr.pdf"
      }
    )
    outcome = nil
    with_identity_flag do
      outcome = structured_route(
        generator, [ chunk ], equipment_identity: orona_identity, question: "no nivela"
      ).execute
    end

    assert_equal 0, generator.converse_calls.size
    assert_equal 1, generator.query_calls.size
    assert_nil outcome.result[:publication_mode]
    assert_includes outcome.result[:answer], "Revisar el sensor"
  end

  private

  def compose(envelope)
    Rag::UnknownIdentityPublication.compose(envelope, chunks: [ zephyr_chunk ], question: QUESTION, locale: :es)
  end

  def guard(text, raw = nil)
    Rag::DocumentIdentityScope.unconfirmed_applicability_violation(text, raw, [ zephyr_chunk ], QUESTION)
  end

  def qualified_envelope(unsafe = nil, observation: SAFE_OBSERVATION)
    observations = [ observation, unsafe ].compact
    {
      "observations" => observations,
      "nameplate_question" => nil,
      "reference_fact" => { "citation" => 1, "fact" => FACT }
    }
  end

  def envelope_json(envelope)
    JSON.generate(envelope)
  end

  def reference_sentence
    "Según el manual ZEPHYR QX-77, página 12 [1], #{FACT}."
  end

  def zephyr_chunk
    {
      content: "ZEPHYR QX-77. Página 12. Q-731 = fallo de puerta.",
      metadata: {
        "canonical_name" => "ZEPHYR QX-77",
        "page_number" => 12,
        "section_identity" => "ZEPHYR QX-77",
        "original_source_uri" => "s3://bucket/zephyr.pdf"
      },
      location_uri: "s3://bucket/chunks/zephyr.txt",
      chunk_sha256: "zephyr-sha",
      rank: 1
    }
  end

  def run_managed(envelope, prose: nil)
    generator = RecordingGenerator.new(envelope, prose: prose)
    chunk = zephyr_chunk
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: [ chunk ], retrieval_trace: {} } }
    service.define_singleton_method(:document_identity_generator) { generator }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| flunk "open rag" }
    result = service.query(QUESTION, equipment_identity: nil, output_channel: :web, response_locale: :es, include_diagnostics: true)
    result.merge(query_calls: generator.query_calls.size)
  end

  def run_structured(envelope)
    generator = RecordingGenerator.new(envelope)
    outcome = structured_route(generator, [ zephyr_chunk ], equipment_identity: nil).execute
    outcome.result.merge(query_calls: generator.query_calls.size)
  end

  def structured_route(generator, chunks, equipment_identity:, question: QUESTION)
    expander = Object.new
    expander.define_singleton_method(:neighbor_chunk) { |**| nil }
    rag = Object.new
    rag.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: chunks, retrieval_trace: {} } }
    Rag::StructuredEvidenceRoute.new(
      question: question,
      account: accounts(:legacy),
      entity_s3_uris: [ "s3://bucket/zephyr.pdf" ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: rag,
      generator: generator,
      expander: expander,
      equipment_identity: equipment_identity
    )
  end

  def orona_identity
    Rag::EquipmentIdentity.new(
      manufacturer: "Orona",
      needles: [ "Orona", "PBCM-V3" ],
      facts: [
        { "slot" => "manufacturer", "value" => "Orona", "source" => "photo", "correlation_id" => "photo:orona" },
        { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "photo:orona" }
      ]
    )
  end

  def with_identity_flag
    previous = ENV.fetch("DOCUMENT_IDENTITY_SCOPE_ENABLED", nil)
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    yield
  ensure
    if previous.nil?
      ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    else
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = previous
    end
  end

  class RecordingGenerator
    attr_reader :converse_calls, :query_calls

    def initialize(envelope, prose: nil)
      @envelope = envelope
      @prose = prose
      @converse_calls = []
      @query_calls = []
    end

    def converse(params)
      @converse_calls << params
      input = @envelope.is_a?(Hash) ? @envelope : nil
      content = if input
        [ OpenStruct.new(tool_use: OpenStruct.new(name: Rag::UnknownIdentityPublication::TOOL_NAME, input: input)) ]
      else
        [ OpenStruct.new(text: "not a tool") ]
      end
      OpenStruct.new(output: OpenStruct.new(message: OpenStruct.new(content: content)), usage: nil)
    end

    def query(prompt, **kwargs)
      @query_calls << { prompt: prompt, **kwargs }
      @prose
    end
  end
end
