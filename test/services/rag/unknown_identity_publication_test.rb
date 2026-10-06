# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Rag::UnknownIdentityPublicationTest < ActiveSupport::TestCase
  QUESTION = "El display muestra Q-731, ¿qué significa?"
  REFUSAL = "I can't give you a procedure to bring the car down"
  FACT = "Q-731 = fallo de puerta"
  PARAPHRASE = "Q-731 aparece como fallo de puerta"
  INVENTED = "Q-731 = fallo del freno"
  SAFE_OBSERVATION = "Mira la posición de la cabina y si las puertas están abiertas."

  test "reference_request is the raw-turn documentary predicate" do
    assert Rag::UnknownIdentityPublication.reference_request?("¿Qué dice el manual ZEPHYR QX-77 en la página 12? Puede no ser mi equipo.")
    assert Rag::UnknownIdentityPublication.reference_request?("What does the ZEPHYR QX-77 manual say? It may not apply to this equipment.")
    assert Rag::UnknownIdentityPublication.reference_request?("El display muestra Q-731, ¿qué significa?")
    assert Rag::UnknownIdentityPublication.reference_request?("El manual BLT que apareció, ¿qué dice sobre su propio sistema de nivelación? No sé si es mi equipo.")
    assert_not Rag::UnknownIdentityPublication.reference_request?("What's the procedure to bring the car down?")
    assert_not Rag::UnknownIdentityPublication.reference_request?("Tengo el manual seleccionado. Dame el procedimiento de rescate.")
    assert_not Rag::UnknownIdentityPublication.reference_request?("Dame los pasos del manual ZEPHYR, yo verifico antes")
    assert_not Rag::UnknownIdentityPublication.reference_request?("¿Y ahora?")
    assert_not Rag::UnknownIdentityPublication.reference_request?("¿y eso?")
    assert_not Rag::UnknownIdentityPublication.reference_request?("Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?")
    assert_not Rag::UnknownIdentityPublication.reference_request?("Este ascensor queda mal nivelado en planta 3; aún no identifiqué la maniobra. ¿Qué observo primero?")
  end

  test "a composed reference question does not classify a later follow-up" do
    assert_not Rag::UnknownIdentityPublication.reference_request?("¿Y ahora?")
    assert Rag::UnknownIdentityPublication.reference_request?("¿Y ahora? ¿Qué dice el manual?")
  end

  test "the schema has no current-job action field" do
    properties = Rag::UnknownIdentityPublication.tool_schema[:properties]

    assert_equal %w[observations reference_fact], properties.keys.map(&:to_s)
    assert_not_includes properties.keys.map(&:to_s), "current_job_actions"
    assert_equal %w[citation evidence_span], properties[:reference_fact][:properties].keys.map(&:to_s)
    assert_equal %w[citation evidence_span], properties[:reference_fact][:required]
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
      "reference_fact" => { "citation" => 1, "evidence_span" => FACT }
    )

    assert_equal "accepted", result.reference_status
    assert_includes result.answer, reference_sentence
    assert_includes result.answer, "Esto no está confirmado para el equipo que tienes delante."
    assert_nil guard(result.answer)
  end

  test "an operation, a measured value, and a setting are dropped" do
    result = compose(
      "observations" => [ "Cortar tensión en el borne XQ7.", SAFE_OBSERVATION ],
      "reference_fact" => { "citation" => 1, "evidence_span" => "Esperar 47 s." },
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
      "reference_fact" => { "citation" => 1, "evidence_span" => "Cortar tensión en el borne XQ7." }
    )

    assert_includes result.answer, SAFE_OBSERVATION
    assert_not_includes result.answer, "bring the car"
    assert_not_includes result.answer, "XQ7"
    assert_equal "rejected", result.reference_status
    assert_nil guard(result.answer)
  end

  test "an exact span from the cited chunk is published as the reference" do
    result = compose("observations" => [], "reference_fact" => { "citation" => 1, "evidence_span" => FACT })

    assert_includes zephyr_chunk[:content], FACT
    assert_equal "accepted", result.reference_status
    assert_includes result.answer, reference_sentence
    assert_nil guard(result.answer)
  end

  test "an invented fact with a valid citation is rejected" do
    [ INVENTED, PARAPHRASE ].each do |fact|
      result = compose(
        "observations" => [ SAFE_OBSERVATION ],
        "reference_fact" => { "citation" => 1, "evidence_span" => fact }
      )

      assert_not_includes zephyr_chunk[:content], fact
      assert_equal "rejected", result.reference_status, fact
      assert_includes result.rejected_fields, "reference_fact"
      assert_not_includes result.answer, fact
      assert_not_includes result.answer, "Según el manual"
      assert_includes result.answer, SAFE_OBSERVATION
      assert_nil guard(result.answer)
    end
  end

  test "a span is checked against the chunk its citation names" do
    other = zephyr_chunk.merge(
      content: "ZEPHYR QX-77. Página 30. Revisa el registro de eventos.",
      metadata: zephyr_chunk[:metadata].merge("page_number" => 30)
    )
    chunks = [ other, zephyr_chunk ]
    wrong = Rag::UnknownIdentityPublication.compose(
      { "observations" => [], "reference_fact" => { "citation" => 1, "evidence_span" => FACT } },
      chunks: chunks, question: QUESTION, locale: :es
    )
    right = Rag::UnknownIdentityPublication.compose(
      { "observations" => [], "reference_fact" => { "citation" => 2, "evidence_span" => FACT } },
      chunks: chunks, question: QUESTION, locale: :es
    )
    missing = compose("observations" => [], "reference_fact" => { "citation" => 4, "evidence_span" => FACT })
    absent = compose("observations" => [], "reference_fact" => { "evidence_span" => FACT })

    assert_equal "rejected", wrong.reference_status
    assert_not_includes wrong.answer, "fallo de puerta"
    assert_equal "accepted", right.reference_status
    assert_includes right.answer, "Según el manual ZEPHYR QX-77, página 12 [2], #{FACT}."
    [ missing, absent ].each do |result|
      assert_equal "rejected", result.reference_status
      assert_not_includes result.answer, "fallo de puerta"
    end
  end

  test "the legacy free-text fact field is not published" do
    result = compose("observations" => [], "reference_fact" => { "citation" => 1, "fact" => FACT })

    assert_equal "rejected", result.reference_status
    assert_not_includes result.answer, "fallo de puerta"
  end

  test "whitespace, composition, markers, and surrounding punctuation do not break grounding" do
    spaced = compose(
      "observations" => [],
      "reference_fact" => { "citation" => 1, "evidence_span" => "  «Q-731\u00A0 =\n fallo   de puerta.» [1]" }
    )
    accented = { content: "Página 3.\nQ-905  =  señal de puerta abierta.", metadata: zephyr_chunk[:metadata] }
    decomposed = Rag::UnknownIdentityPublication.compose(
      {
        "observations" => [],
        "reference_fact" => { "citation" => 1, "evidence_span" => "Q-905 = señal de puerta abierta".unicode_normalize(:nfd) }
      },
      chunks: [ accented ], question: "El display muestra Q-905, ¿qué significa?", locale: :es
    )

    assert_equal "accepted", spaced.reference_status
    assert_includes spaced.answer, reference_sentence
    assert_equal "accepted", decomposed.reference_status
    assert_includes decomposed.answer, "página 12 [1], Q-905 = señal de puerta abierta."
  end

  test "a span cut inside a token is not grounded" do
    [ "731 = fallo de puerta", "Q-731 = fallo de puert", "Q-731 = fallo de puerta y freno" ].each do |span|
      result = compose("observations" => [], "reference_fact" => { "citation" => 1, "evidence_span" => span })

      assert_equal "rejected", result.reference_status, span
    end
  end

  test "a subspan that drops a negation is rejected and the whole fragment is accepted" do
    negated = zephyr_chunk.merge(content: "ZEPHYR QX-77. Página 12.\nQ-731 no indica fallo de freno. Revisa el registro.")
    outcome = lambda do |span|
      Rag::UnknownIdentityPublication.compose(
        { "observations" => [ SAFE_OBSERVATION ], "reference_fact" => { "citation" => 1, "evidence_span" => span } },
        chunks: [ negated ], question: QUESTION, locale: :es
      )
    end

    [ "fallo de freno", "indica fallo de freno", "Q-731 no indica fallo" ].each do |span|
      result = outcome.call(span)

      assert_equal "rejected", result.reference_status, span
      assert_not_includes result.answer, "fallo de freno"
      assert_includes result.answer, SAFE_OBSERVATION
    end
    whole = outcome.call(" Q-731  no indica\nfallo de freno. ")
    assert_equal "accepted", whole.reference_status
    assert_includes whole.answer, "Según el manual ZEPHYR QX-77, página 12 [1], Q-731 no indica fallo de freno."
    assert_nil Rag::DocumentIdentityScope.unconfirmed_applicability_violation(whole.answer, nil, [ negated ], QUESTION)
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
    assert_includes managed[:guidance_prompt], "# FIELD COMPANION"
    assert_not_includes managed[:guidance_prompt], "fallo de puerta"
    assert_not_includes managed[:guidance_prompt], "APPLICABILITY_BLOCK"
  end

  test "c12 enters the publication contract on both lanes and c04 stays body-free guidance" do
    c12 = "What does the ZEPHYR QX-77 manual say? It may not apply to this equipment."
    c04 = "What's the procedure to bring the car down?"
    prior = "## Session Focus\nGround your answer in SEGURIDAD IN.\n## Recent Conversation\nAssistant: Paso 11. Ajusta el interruptor."

    [ c12 ].each do |question|
      managed = run_managed(qualified_envelope, question: question)
      structured = run_structured(qualified_envelope, question: question)
      [ managed, structured ].each do |result|
        assert_equal 1, result[:converse_calls]
        assert_equal 0, result[:query_calls]
        assert_equal "unknown_identity_contract", result[:publication_mode]
        assert_includes result[:answer], "Esto no está confirmado para el equipo que tienes delante."
      end
    end

    [ c04 ].each do |question|
      managed = run_managed(qualified_envelope, question: question, session_context: prior, prose: "Mirar la posición de la cabina.")
      structured = run_structured(qualified_envelope, question: question, session_context: prior, prose: "Mirar la posición de la cabina.")
      [ managed, structured ].each do |result|
        assert_equal 0, result[:converse_calls]
        assert_equal 1, result[:query_calls]
        assert_equal "unknown_identity_guidance", result[:publication_mode]
        assert_includes result[:guidance_prompt], "# FIELD COMPANION"
        assert_includes result[:guidance_prompt], question
        assert_not_includes result[:guidance_prompt], "fallo de puerta"
        assert_not_includes result[:guidance_prompt], "Paso 11"
        assert_not_includes result[:guidance_prompt], "## Session Focus"
        assert_not_includes result[:guidance_prompt], "APPLICABILITY_BLOCK"
      end
    end
  end

  test "a rejected span on both lanes becomes body-free guidance without a qualified reference" do
    rejected = { "observations" => [ SAFE_OBSERVATION ], "reference_fact" => { "citation" => 1, "evidence_span" => "Cortar tensión en el borne XQ7." } }
    prose = "La cabina está por encima del nivel."
    [ run_managed(rejected, prose: prose), run_structured(rejected, prose: prose) ].each do |result|
      assert_equal 1, result[:converse_calls]
      assert_equal 1, result[:query_calls]
      assert_equal "unknown_identity_guidance", result[:publication_mode]
      assert_includes result[:guidance_prompt], "# FIELD COMPANION"
      assert_not_includes result[:guidance_prompt], "fallo de puerta"
      assert_not_includes result[:answer], "Según el manual"
      assert_not_includes result[:answer], "XQ7"
    end
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
      "reference_fact" => { "citation" => 1, "evidence_span" => FACT }
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

  def run_managed(envelope, prose: nil, question: QUESTION, session_context: nil)
    generator = RecordingGenerator.new(envelope, prose: prose)
    chunk = zephyr_chunk
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.define_singleton_method(:retrieve_chunks) { |*, **| { chunks: [ chunk ], retrieval_trace: {} } }
    service.define_singleton_method(:document_identity_generator) { generator }
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| flunk "open rag" }
    result = service.query(
      question, equipment_identity: nil, output_channel: :web, response_locale: :es,
      include_diagnostics: true, session_context: session_context, raw_question: question
    )
    result.merge(
      query_calls: generator.query_calls.size,
      converse_calls: generator.converse_calls.size,
      guidance_prompt: generator.query_calls.last&.dig(:prompt).to_s
    )
  end

  def run_structured(envelope, question: QUESTION, session_context: nil, prose: nil)
    generator = RecordingGenerator.new(envelope, prose: prose)
    outcome = structured_route(
      generator, [ zephyr_chunk ], equipment_identity: nil, question: question, session_context: session_context
    ).execute
    outcome.result.merge(
      query_calls: generator.query_calls.size,
      converse_calls: generator.converse_calls.size,
      guidance_prompt: generator.query_calls.last&.dig(:prompt).to_s
    )
  end

  def structured_route(generator, chunks, equipment_identity:, question: QUESTION, session_context: nil)
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
      equipment_identity: equipment_identity,
      raw_question: question,
      session_context: session_context
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
