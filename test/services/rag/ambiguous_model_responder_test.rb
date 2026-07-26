# frozen_string_literal: true

require "test_helper"

class Rag::AmbiguousModelResponderTest < ActiveSupport::TestCase
  FakeService = Struct.new(:chunks) do
    def retrieve_chunks(*)
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

  test "intent accepts a generic LED question and rejects a named model" do
    assert Rag::DeterministicIntent.ambiguous_hardware_query?("¿Qué LED se enciende cuando falla?")
    assert_not Rag::DeterministicIntent.ambiguous_hardware_query?("¿Qué indica DL27 en TOKIBAT?")
    assert_not Rag::DeterministicIntent.ambiguous_hardware_query?("¿Qué LED indica fallo en EM3000?")
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

  private

  def build_responder(*chunks)
    Rag::AmbiguousModelResponder.new(
      question: "¿Qué LED se enciende cuando falla?",
      account: accounts(:legacy),
      entity_s3_uris: [],
      entity_sources: [],
      force_entity_filter: false,
      response_locale: :es,
      rag_service: FakeService.new(chunks)
    )
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
