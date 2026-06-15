# frozen_string_literal: true

require "test_helper"

class LlmJsonParserTest < ActiveSupport::TestCase
  test "parses strict JSON" do
    parsed = LlmJsonParser.parse('{"chunks":[{"text":"ok","page":1}]}')

    assert_equal "ok", parsed.dig("chunks", 0, "text")
  end

  test "parses fenced JSON" do
    parsed = LlmJsonParser.parse("```json\n{\"chunks\":[{\"text\":\"ok\",\"page\":1}]}\n```")

    assert_equal 1, parsed.dig("chunks", 0, "page")
  end

  test "repairs unescaped quoted words inside chunk text" do
    raw = '{"chunks":[{"text":"Consulte la sección "Etiquetas" y "Mantenimiento".","page":6}]}'

    parsed = LlmJsonParser.parse(raw)

    assert_equal 'Consulte la sección "Etiquetas" y "Mantenimiento".',
                 parsed.dig("chunks", 0, "text")
  end

  test "repairs B3 markdown bold quoted words inside chunk text" do
    raw = '{"chunks":[{"text":"Use el control de **"plataforma"** y cambie a **"apagado"**.","page":3}]}'

    parsed = LlmJsonParser.parse(raw)

    assert_equal 'Use el control de **"plataforma"** y cambie a **"apagado"**.',
                 parsed.dig("chunks", 0, "text")
  end

  test "repairs quoted labels followed by colon inside a value string" do
    raw = '{"chunks":[{"text":"El visor muestra "Voltage": 24 V antes de iniciar.","page":8}]}'

    parsed = LlmJsonParser.parse(raw)

    assert_equal 'El visor muestra "Voltage": 24 V antes de iniciar.',
                 parsed.dig("chunks", 0, "text")
  end

  test "repairs comma-separated quoted values inside chunk text" do
    raw = '{"chunks":[{"text":"El selector puede estar en "encendido", "APAGADO", "ON" según la etiqueta.","page":8}]}'

    parsed = LlmJsonParser.parse(raw)

    assert_equal 'El selector puede estar en "encendido", "APAGADO", "ON" según la etiqueta.',
                 parsed.dig("chunks", 0, "text")
  end

  test "does not synthesize missing JSON structure" do
    broken = '{"chunks":[{"text":"unterminated","page":6}'

    assert_raises(JSON::ParserError) { LlmJsonParser.parse(broken) }
    assert_not LlmJsonParser.parseable?(broken)
  end
end
