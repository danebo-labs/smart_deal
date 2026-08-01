# frozen_string_literal: true

require "test_helper"

class Rag::AmbiguousModelResponderTest < ActiveSupport::TestCase
  # Measured 2026-07-31 in tmp/pilot_gate/pilot_10q_v4_1.json: the board is
  # named unambiguously, yet the question reaches this responder because
  # "TWISTER TW" carries no digit for EXPLICIT_EQUIPMENT_PATTERN to catch.
  TWISTER_QUESTION =
    "Estoy con una Twister TW de Embarba eléctrica y sospecho de la serie de puertas. " \
    "¿Qué LED de la placa me lo confirma?"
  GENERIC_QUESTION = "¿Qué LED se enciende cuando falla?"

  FakeService = Struct.new(:chunks) do
    attr_reader :captured_kwargs, :retrieve_count

    def retrieve_chunks(*, **kwargs)
      @captured_kwargs = kwargs
      @retrieve_count = @retrieve_count.to_i + 1
      {
        chunks: chunks,
        retrieval_trace: {
          resolved_scope_s3_uris: [],
          applied_filter_s3_uris: [],
          force_entity_filter: false
        }
      }
    end
  end

  class FakeGenerator
    attr_reader :calls, :prompt

    def initialize(answer)
      @answer = answer
      @calls = 0
    end

    def query(prompt, **)
      @calls += 1
      @prompt = prompt
      @answer
    end
  end

  setup do
    @original_route_flag = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
  end

  teardown do
    if @original_route_flag.nil?
      ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED")
    else
      ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = @original_route_flag
    end
  end

  test "intent accepts a generic LED question and rejects a named model" do
    assert Rag::DeterministicIntent.ambiguous_hardware_query?(GENERIC_QUESTION)
    assert_not Rag::DeterministicIntent.ambiguous_hardware_query?("¿Qué indica DL27 en TOKIBAT?")
    assert_not Rag::DeterministicIntent.ambiguous_hardware_query?("¿Qué LED indica fallo en EM3000?")
  end

  # Hallazgo 8 of the pilot plan claims EDEL-K2 is the same open bug as
  # TWISTER TW. It is not: 4a66b01 (2026-07-28) added the optional letter to
  # EXPLICIT_EQUIPMENT_PATTERN, so EDEL-K2 has been routed past this responder
  # since that day. Only a board with no digit at all still reaches it.
  test "a hyphenated board with a digit no longer reads as ambiguous, one without a digit still does" do
    assert_not Rag::DeterministicIntent.ambiguous_hardware_query?(
      "En la EDEL-K2, ¿qué LED indica que los cerrojos están cerrados?"
    )
    assert Rag::DeterministicIntent.ambiguous_hardware_query?(TWISTER_QUESTION)
  end

  test "returns three evidence-backed choices when several boards are retrieved" do
    responder = build_responder(
      chunk("TOKIBAT", "DL27 TOKIBAT", page: 39),
      chunk("THYSSEN", "THYSSEN-E LED diagnostic", page: 93),
      chunk("ORONA", "ORONA MR08 LED status", page: 22),
      chunk("ALTIUS", "ALTIUS-D8 indicator", page: 7)
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_equal false, result[:model_invoked]
    assert_equal 3, result[:quick_replies].size
    assert_equal "TOKIBAT — DL27", result.dig(:quick_replies, 0, :label)
    assert_includes result.dig(:quick_replies, 0, :query), "¿Qué LED se enciende cuando falla?"
    assert_includes result[:answer], "varias placas o modelos"
    assert_equal [ 39, 93, 22 ], result[:citations].pluck(:page)
  end

  test "falls through when retrieval does not expose three distinct models" do
    responder = build_responder(
      chunk("TOKIBAT", "DL27 TOKIBAT", page: 39),
      chunk("THYSSEN", "THYSSEN-E LED diagnostic", page: 93)
    )

    assert_nil responder.execute
  end

  test "uses documented diagram headings when manufacturer metadata is absent" do
    responder = build_responder(
      heading_chunk("## S7 — DIAGRAM: CTA – M8PC (ELÉCTRICO Y HIDRÁULICO) / BORNAS CARRIL", 54),
      heading_chunk("## S4 — SAFETY SYSTEM: ARCA III — Diagrama de Series", 52),
      heading_chunk("## S7 — DIAGRAM: MAC 5000 — Esquema de Cadena", 55)
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_equal [ "CTA – M8PC (ELÉCTRICO Y HIDRÁULICO)", "ARCA III", "MAC 5000" ],
                 result[:quick_replies].pluck(:label)
  end

  test "does not fabricate a manufacturer from unrelated text in the chunk body" do
    responder = build_responder(
      heading_chunk("## EM 4000 V1\nCadena de seguridades ALTIUS conectada en serie.", 33),
      heading_chunk("## S4 — SAFETY SYSTEM: ARCA III — Diagrama de Series", 52),
      heading_chunk("## S7 — DIAGRAM: MAC 5000 — Esquema de Cadena", 55)
    )

    result = responder.execute

    labels = result[:quick_replies].pluck(:label)
    assert_not labels.any? { |label| label.start_with?("ALTIUS — ") }
    assert_includes labels, "EM 4000 V1"
  end

  test "web omits the numbered list because chips already carry the options" do
    responder = build_responder(
      chunk("TOKIBAT", "DL27 TOKIBAT", page: 39),
      chunk("THYSSEN", "THYSSEN-E LED diagnostic", page: 93),
      chunk("ORONA", "ORONA MR08 LED status", page: 22),
      output_channel: :web
    )

    result = responder.execute

    assert_not_includes result[:answer], "1."
    assert_equal 3, result[:quick_replies].size
  end

  test "non-web keeps the numbered list for channels without chips" do
    responder = build_responder(
      chunk("TOKIBAT", "DL27 TOKIBAT", page: 39),
      chunk("THYSSEN", "THYSSEN-E LED diagnostic", page: 93),
      chunk("ORONA", "ORONA MR08 LED status", page: 22)
    )

    result = responder.execute

    assert_includes result[:answer], "1. "
  end

  test "asks the retrieval layer for the contractual top_k" do
    responder = build_responder(
      chunk("TOKIBAT", "DL27 TOKIBAT", page: 39),
      chunk("THYSSEN", "THYSSEN-E LED diagnostic", page: 93),
      chunk("ORONA", "ORONA MR08 LED status", page: 22)
    )

    responder.execute

    assert_equal 20, responder.instance_variable_get(:@service).captured_kwargs[:number_of_results]
  end

  test "answers from the retrieval in hand when the question already names one board" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    generator = FakeGenerator.new("El LED SSEG confirma la serie de puertas. [1]")
    responder = build_responder(
      *twister_chunks,
      question: TWISTER_QUESTION,
      generator: generator
    )

    result = responder.execute

    assert_equal "structured_evidence_route", result[:generation_mode]
    assert_nil result[:quick_replies]
    assert_includes result[:answer], "SSEG"
    assert_equal 1, generator.calls
    assert_includes generator.prompt, "TWISTER TW"
    assert_not_includes generator.prompt, "EDEL-K3"
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
  end

  test "an abstention from the route is still terminal, so the turn spends one retrieve" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    responder = build_responder(
      *twister_chunks,
      question: TWISTER_QUESTION,
      generator: FakeGenerator.new("")
    )

    result = responder.execute

    assert_not_nil result
    assert_equal "structured_evidence_route", result[:generation_mode]
    assert_equal :generation_failure, result.dig(:diagnostics, :outcome_reason)
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
  end

  test "the menu keeps only the boards the question named when it names more than one" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    responder = build_responder(
      *twister_chunks,
      question: "#{TWISTER_QUESTION} También tengo una Level Control 1B premontada.",
      generator: FakeGenerator.new("no debería generarse [1]")
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_equal [ "TWISTER TW – ELECTRICO - EMBARBA", "LEVEL CONTROL 1B – ELECTRICO - PREMONTADA" ],
                 result[:quick_replies].pluck(:label)
  end

  # The regression that stops the filter from disabling disambiguation whole:
  # a question that names no board must still get the three-way menu.
  test "a question that names no board still gets the menu" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    generator = FakeGenerator.new("no debería generarse [1]")
    responder = build_responder(*twister_chunks, generator: generator)

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_equal 3, result[:quick_replies].size
    assert_equal 0, generator.calls
  end

  test "with the live route flag off a named board still gets the menu it gets today" do
    responder = build_responder(
      *twister_chunks,
      question: TWISTER_QUESTION,
      generator: FakeGenerator.new("no debería generarse [1]")
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_equal "TWISTER TW – ELECTRICO - EMBARBA", result.dig(:quick_replies, 0, :label)
  end

  private

  def build_responder(*chunks, output_channel: nil, question: GENERIC_QUESTION, generator: nil)
    Rag::AmbiguousModelResponder.new(
      question: question,
      account: accounts(:legacy),
      entity_s3_uris: [],
      entity_sources: [],
      force_entity_filter: false,
      response_locale: :es,
      output_channel: output_channel,
      rag_service: FakeService.new(chunks),
      generator: generator
    )
  end

  # The three labels the twister case actually retrieved (v4.1 artifact).
  def twister_chunks
    [
      board_chunk(
        "## S7 — DIAGRAM: TWISTER TW – ELECTRICO - EMBARBA",
        "El LED SSEG de la placa TW confirma la serie de puertas.",
        page: 89
      ),
      board_chunk(
        "## S7 — DIAGRAM: LEVEL CONTROL 1B – ELECTRICO - PREMONTADA",
        "Cadena de seguridades de la placa premontada.",
        page: 62
      ),
      board_chunk(
        "## EDEL-K3 Wiring Overview — Safety & Door Circuit Connections",
        "Conexionado de la cadena de puertas.",
        page: 25
      )
    ]
  end

  def board_chunk(heading, body, page:)
    {
      content: "#{heading}\n\n#{body}",
      location_uri: "s3://bucket/chunks/chunk_#{page - 2}.txt",
      original_source_uri: "s3://bucket/seguridades.pdf",
      chunk_sha256: "sha-#{page}",
      rank: page,
      metadata: {
        "canonical_name" => "SEGURIDADES 1.1-1.pdf",
        "original_source_uri" => "s3://bucket/seguridades.pdf",
        "page_number" => page
      }
    }
  end

  def chunk(manufacturer, content, page:)
    {
      content: content,
      location_uri: "s3://bucket/#{manufacturer.downcase}.txt",
      original_source_uri: "s3://bucket/#{manufacturer.downcase}.pdf",
      metadata: {
        "manufacturer" => manufacturer,
        "canonical_name" => "#{manufacturer} manual",
        "page_number" => page
      }
    }
  end

  def heading_chunk(heading, page)
    {
      content: heading,
      location_uri: "s3://bucket/chunk_p#{page}_1.txt",
      original_source_uri: "s3://bucket/seguridades.pdf",
      metadata: {}
    }
  end
end
