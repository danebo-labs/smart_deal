# frozen_string_literal: true

require "test_helper"

module Rag
  class FacetedAnswerTest < ActiveSupport::TestCase
    SAMPLE = <<~ANS
      [INTENT] IDENTIFICATION
      [RESUMEN]
      Orona PCB Mainboard es la placa principal del controlador. Maneja motor, freno, puertas y diagnóstico por LEDs. ⚙️
      [RIESGOS]
      Tensión residual tras LOTO: verificar con multímetro.
      ⚠️ REQUIERE VERIFICACIÓN EN CAMPO
      [PARÁMETROS]
      ① Alimentación: 24VDC ± 10%
      ② Torque terminales: 0.5 Nm
      [SECCIONES]
      - Diagnóstico por LEDs
      - Conectores
      - Procedimiento de reemplazo
      [DETALLE]
      Paso 1: aislar con LOTO.
      Paso 2: retirar conectores.
      [MENU]
      1 | ⚠️ Riesgos | riesgos
      2 | 📏 Parámetros | parametros
      3 | 📋 Secciones | secciones
      4 | 🔧 Detalle | detalle
    ANS

    test "parses all labeled blocks" do
      f = FacetedAnswer.parse(SAMPLE)

      assert_equal :identification, f.intent
      assert_match(/Orona PCB Mainboard/, f.facets[:resumen])
      assert_match(/REQUIERE VERIFICACIÓN/, f.facets[:riesgos])
      assert_match(/24VDC/, f.facets[:parametros])
      assert_match(/Diagnóstico por LEDs/, f.facets[:secciones])
      assert_match(/Paso 1/, f.facets[:detalle])
      assert_equal 4, f.menu.size
      assert_equal :riesgos, f.menu.first[:facet_key]
      assert_not f.empty?
      assert_not f.legacy?
    end

    test "handles empty facet marker (—)" do
      text = <<~ANS
        [INTENT] IDENTIFICATION
        [RESUMEN]
        Esquema SOPREL básico.
        [RIESGOS]
        (—)
        [PARÁMETROS]
        (—)
        [SECCIONES]
        - Diagrama general
        [DETALLE]
        Detalle del esquema.
        [MENU]
        3 | Secciones | secciones
        4 | Detalle | detalle
      ANS

      f = FacetedAnswer.parse(text)
      assert f.facet_empty?(:riesgos)
      assert f.facet_empty?(:parametros)
      assert_not f.facet_empty?(:secciones)
      assert_not f.facet_empty?(:detalle)
      assert_equal 2, f.menu.size
    end

    test "falls back to :detalle when no labels present" do
      plain = "This is a legacy answer without any labels."
      f     = FacetedAnswer.parse(plain)
      assert_equal :identification, f.intent
      assert_equal plain, f.facets[:detalle]
      assert f.legacy?
      assert_empty f.facets[:resumen]
    end

    test "unknown intent token falls back to :identification" do
      text = "[INTENT] BOGUS\n[RESUMEN]\nHola\n[DETALLE]\nMundo\n"
      f    = FacetedAnswer.parse(text)
      assert_equal :identification, f.intent
    end

    test "emergency intent is recognized" do
      text = "[INTENT] EMERGENCY\n[RESUMEN]\nProtocolo de rescate…\n[DETALLE]\nPasos…\n"
      f    = FacetedAnswer.parse(text)
      assert_equal :emergency, f.intent
      assert f.emergency?
    end

    test "round-trip via to_cache_hash and from_cache" do
      original = FacetedAnswer.parse(SAMPLE)
      restored = FacetedAnswer.from_cache(original.to_cache_hash)

      assert_equal original.intent, restored.intent
      assert_equal original.facets[:resumen], restored.facets[:resumen]
      assert_equal original.menu, restored.menu
    end

    test "blank text produces empty fallback" do
      f = FacetedAnswer.parse("   ")
      assert f.legacy?
      assert_equal "", f.facets[:detalle]
    end

    test "menu line without explicit facet_key infers from label" do
      text = "[INTENT] IDENTIFICATION\n[RESUMEN]\nX\n[MENU]\n1 | Riesgos del equipo\n2 | Secciones\n"
      f    = FacetedAnswer.parse(text)
      assert_equal :riesgos, f.menu[0][:facet_key]
      assert_equal :secciones, f.menu[1][:facet_key]
    end

    test "menu block marked (—) yields empty menu" do
      text = "[INTENT] EMERGENCY\n[RESUMEN]\nRescate...\n[MENU]\n(—)\n"
      f    = FacetedAnswer.parse(text)
      assert_empty f.menu
    end

    test "from_cache with blank hash returns fallback" do
      f = FacetedAnswer.from_cache(nil)
      assert f.legacy?
    end

    # --- R2 UX render -------------------------------------------------------

    test "to_whatsapp_first_message renders vertical text-only menu with back/home nav" do
      msg = FacetedAnswer.parse(SAMPLE).to_whatsapp_first_message(locale: :es)
      assert_includes msg, "Opciones:\n"
      assert_match(/^1 - Riesgos$/, msg)
      assert_match(/^4 - Detalle$/, msg)
      assert_no_match(/^1 - ⚠️/, msg, "facet labels must not carry emojis anymore")
      # Blank line separates facets from nav; 5=regresar / 6=inicio appear last.
      assert_match(/\n\n5 - regresar\n6 - inicio\z/, msg)
    end

    test "to_whatsapp_first_message includes document_label as source prefix" do
      msg = FacetedAnswer.parse(SAMPLE).to_whatsapp_first_message(locale: :es, document_label: "PCB Mainboard Orona")
      assert_match(/\A\*PCB Mainboard Orona\* \(fuente\)/, msg)
    end

    test "to_facet_message composes compact header with document label" do
      msg = FacetedAnswer.parse(SAMPLE).to_facet_message(:riesgos, locale: :es, document_label: "PCB Orona")
      # Short label fits on one line inside the header.
      assert_match(/\*Riesgos · PCB Orona\*/, msg)
      # Emoji is NOT kept in facet header (reduce icon noise on follow-ups).
      assert_no_match(/\*⚠️ Riesgos/, msg)
    end

    test "to_facet_message falls back to inline source when combined header is too long" do
      long = "Documento muy largo que no entra en el header compacto"
      msg  = FacetedAnswer.parse(SAMPLE).to_facet_message(:riesgos, locale: :es, document_label: long)
      assert_match(/^\*Riesgos\*$/, msg)
      assert_includes msg, "(del documento *#{long}*)"
    end

    test "to_facet_message hoists matching line when highlight is provided" do
      content = <<~ANS
        [INTENT] IDENTIFICATION
        [RESUMEN]
        PCB Orona.
        [PARÁMETROS]
        ① Tipo: CR2032
        ② Arquitectura: mixta
        ⚠️ Voltaje de operación: DATO NO DISPONIBLE
        [MENU]
        2 | 📏 Parámetros | parametros
      ANS
      msg = FacetedAnswer.parse(content).to_facet_message(:parametros, locale: :es, highlight: "voltaje")
      assert_match(/🔎 \*Voltaje\*/, msg)
      voltage_pos = msg.index("Voltaje de operación")
      tipo_pos    = msg.index("Tipo: CR2032")
      assert voltage_pos < tipo_pos, "voltage line must be hoisted above the other params"
    end

    test "to_facet_message emits missing-topic notice when highlight is absent" do
      content = <<~ANS
        [INTENT] IDENTIFICATION
        [PARÁMETROS]
        ① Tipo: CR2032
        [MENU]
        2 | 📏 Parámetros | parametros
      ANS
      msg = FacetedAnswer.parse(content).to_facet_message(:parametros, locale: :es, highlight: "torque")
      assert_match(/🔎 \*Torque\*/, msg)
      assert_match(/No hay torque documentado/i, msg)
    end

    test "render footer drops emojis and appends 5-regresar / 6-inicio nav" do
      msg = FacetedAnswer.parse(SAMPLE).to_facet_message(:riesgos, locale: :es)
      # Footer lists the OTHER menu items without emojis.
      assert_match(/^2 - Par.*metros$/, msg)
      assert_no_match(/^2 - 📏/, msg)
      assert_match(/\n\n5 - regresar\n6 - inicio\z/, msg)
    end
  end
end
