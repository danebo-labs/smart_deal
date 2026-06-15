# frozen_string_literal: true

require "test_helper"

class FieldPhotoResultsParserTest < ActiveSupport::TestCase
  BENCHMARK_JSON = {
    "canonical_component"      => "Door Operator Motor",
    "manufacturer"             => "Schindler",
    "model"                    => "5500",
    "subsystem"                => "DOOR_OPERATOR",
    "condition"                => "GOOD",
    "aliases"                  => %w[HPM-400 orona hydraulic],
    "summary"                  => "Parece el motor del operador de puerta de un Schindler.",
    "anti_hallucination_notes" => "Manufacturer visible on label."
  }.freeze

  test "transforms benchmark JSON into valid envelope" do
    envelope = FieldPhotoResultsParser.to_envelope(BENCHMARK_JSON.to_json)

    assert_equal "Door Operator Motor", envelope["document_name"]
    assert_equal %w[HPM-400 orona hydraulic], envelope["aliases"]
    assert_equal "Parece el motor del operador de puerta de un Schindler.", envelope["summary"]
    assert_equal 1, envelope["chunks"].size
    assert_equal 1, envelope["chunks"].first["page"]
    assert_equal %w[HPM-400 orona hydraulic], envelope["chunks"].first["aliases"]
  end

  test "chunk body includes identification fields" do
    envelope = FieldPhotoResultsParser.to_envelope(BENCHMARK_JSON.to_json)
    body     = envelope["chunks"].first["text"]

    assert_includes body, "Component: Door Operator Motor"
    assert_includes body, "Manufacturer: Schindler"
    assert_includes body, "Model: 5500"
    assert_not_includes body, "Subsystem:"
    assert_includes body, "Condition: GOOD"
    assert_includes body, "Visible labels: HPM-400, orona, hydraulic"
    assert_includes body, "Technical evidence: DATA_NOT_AVAILABLE beyond visible identification."
    assert_includes body, "Notes: Manufacturer visible on label."
  end

  test "preserves explicit technical evidence from a photographed diagram" do
    payload = BENCHMARK_JSON.merge(
      "visible_text" => [ "P41 TEST PORT", "24 VDC" ],
      "documented_functions" => [
        {
          "label" => "P41",
          "function" => "Pressure test port",
          "evidence" => "Legend: P41 TEST PORT"
        }
      ],
      "documented_connections" => [
        {
          "from" => "P41",
          "to" => "RV1",
          "evidence" => "Continuous visible line between P41 and RV1"
        }
      ],
      "documented_values" => [
        {
          "label" => "X1",
          "value" => "24",
          "unit" => "VDC",
          "evidence" => "Printed text: X1 24 VDC"
        }
      ],
      "documented_warnings" => [ "Disconnect power before service" ]
    )

    body = FieldPhotoResultsParser.to_envelope(payload.to_json)["chunks"].first["text"]

    assert_includes body, "Visible text:\n- P41 TEST PORT\n- 24 VDC"
    assert_includes body, "P41: Pressure test port | Evidence: Legend: P41 TEST PORT"
    assert_includes body, "P41 -> RV1 | Evidence: Continuous visible line between P41 and RV1"
    assert_includes body, "X1: 24 VDC | Evidence: Printed text: X1 24 VDC"
    assert_includes body, "Documented warnings:\n- Disconnect power before service"
    assert_not_includes body, "Technical evidence: DATA_NOT_AVAILABLE"
  end

  test "ignores malformed structured evidence entries" do
    payload = BENCHMARK_JSON.merge(
      "documented_functions" => [ "not a hash", nil ],
      "documented_connections" => [ 123 ],
      "documented_values" => [ [] ]
    )

    body = FieldPhotoResultsParser.to_envelope(payload.to_json)["chunks"].first["text"]

    assert_includes body, "Technical evidence: DATA_NOT_AVAILABLE beyond visible identification."
    assert_not_includes body, "Documented functions:"
  end

  test "missing canonical_component falls back to i18n unknown_component (en)" do
    json     = BENCHMARK_JSON.except("canonical_component").to_json
    envelope = I18n.with_locale(:en) { FieldPhotoResultsParser.to_envelope(json) }

    assert_equal "Unknown Component", envelope["document_name"]
  end

  test "missing canonical_component falls back to i18n unknown_component (es)" do
    json     = BENCHMARK_JSON.except("canonical_component").to_json
    envelope = I18n.with_locale(:es) { FieldPhotoResultsParser.to_envelope(json) }

    assert_equal "Componente desconocido", envelope["document_name"]
  end

  test "nil summary when JSON has no summary key" do
    json     = BENCHMARK_JSON.except("summary").to_json
    envelope = FieldPhotoResultsParser.to_envelope(json)

    assert_nil envelope["summary"]
  end

  test "invalid JSON raises BatchResultsParserService::ParseError" do
    assert_raises(BatchResultsParserService::ParseError) do
      FieldPhotoResultsParser.to_envelope("not json {{{")
    end
  end

  test "strips markdown fences before parsing" do
    fenced = "```json\n#{BENCHMARK_JSON.to_json}\n```"
    envelope = FieldPhotoResultsParser.to_envelope(fenced)

    assert_equal "Door Operator Motor", envelope["document_name"]
  end

  test "repairs unescaped quoted words before transforming benchmark JSON" do
    raw = '{"canonical_component":"Botón "STOP"","manufacturer":"Schindler","model":"5500",' \
      '"aliases":["STOP"],"summary":"Botón de parada.","anti_hallucination_notes":"Visible en foto."}'

    envelope = FieldPhotoResultsParser.to_envelope(raw)

    assert_equal 'Botón "STOP"', envelope["document_name"]
  end
end
