# frozen_string_literal: true

require "test_helper"

module Rag
  class FacetedAnswerTest < ActiveSupport::TestCase
    INSTALL_SAMPLE = <<~ANS
      [INTENT] INSTALLATION
      [DOCS]
      ["Manual Orono A1", "Transformadores.pdf"]
      [RESUMEN]
      Para instalar el ascensor Orono A1 se combinan el Manual Orono A1 (estructura mecánica) y Transformadores.pdf (alimentación). Se valida en 4 etapas críticas. 🛠
      [RIESGOS]
      ⚠️ LOTO obligatorio antes de conectar el transformador.
      ⚠️ *VOLTAJE NO VERIFICADO — confirmar antes de intervenir*
      [SECCIONES]
      ## Consideraciones iniciales | Manual Orono A1
      Validar plomada y nivelación del hueco. Revisar hoja técnica.

      ## Componentes | Manual Orono A1, Transformadores.pdf
      ① Contrapeso.
      ② Cabina.
      ③ Transformador 220/24V.

      ## Paso a paso | Manual Orono A1, Transformadores.pdf
      1. Fijar guías.
      2. Conectar alimentación.
      3. Ajustar freno.

      ## Verificación | Manual Orono A1
      Pruebas de recorrido + inspección de seguridad.
      [MENU]
      1 | ⚠️ Riesgos | __riesgos__
      2 | Consideraciones iniciales | __sec_1__
      3 | Componentes | __sec_2__
      4 | Paso a paso | __sec_3__
      5 | Verificación | __sec_4__
      6 | 🔄 Nueva consulta | __new_query__
    ANS

    # --- parse --------------------------------------------------------------

    test "parses intent, docs, resumen, riesgos, sections and menu" do
      f = FacetedAnswer.parse(INSTALL_SAMPLE)

      assert_equal :installation, f.intent
      assert_equal [ "Manual Orono A1", "Transformadores.pdf" ], f.docs
      assert_match(/Manual Orono A1/, f.resumen)
      assert_match(/Transformadores/, f.resumen)
      assert_match(/LOTO obligatorio/, f.riesgos)

      assert_equal 4, f.sections.length
      assert_equal [ "Consideraciones iniciales", "Componentes", "Paso a paso", "Verificación" ],
                   f.sections.pluck(:label)
      assert_equal [ "Manual Orono A1" ], f.sections.first[:sources]
      assert_equal [ "Manual Orono A1", "Transformadores.pdf" ], f.sections[1][:sources]

      # 1 risk slot + 4 sections + 2 listing slots. The legacy
      # __new_query__ row from Haiku is stripped by append_list_options.
      assert_equal 7, f.menu.length
      assert_equal :riesgos,     f.menu[0][:kind]
      assert_equal :section,     f.menu[1][:kind]
      assert_equal :sec_1,       f.menu[1][:section_key]
      assert_equal :list_recent, f.menu[-2][:kind]
      assert_equal :list_all,    f.menu[-1][:kind]
      assert_not f.menu.any? { |m| m[:kind] == :new_query }, "new_query row must be stripped"

      assert_not f.legacy?
      assert_not f.empty?
      assert_not f.riesgos_empty?
    end

    test "parses [DOCS] as JSON and caps to 5 + 40 chars per entry" do
      text = <<~ANS
        [INTENT] IDENTIFICATION
        [DOCS]
        ["a","b","c","d","e","f","  this is a very long document name exceeding the forty chars cap  "]
        [RESUMEN]
        x
        [RIESGOS]
        ok
        [SECCIONES]
        ## Uno | a
        body
        [MENU]
        1 | Riesgos | __riesgos__
        2 | Uno | __sec_1__
        3 | Nueva consulta | __new_query__
      ANS
      f = FacetedAnswer.parse(text)
      assert_equal 5, f.docs.length
      assert_equal %w[a b c d e], f.docs
    end

    test "parses [DOCS] with malformed JSON via CSV fallback" do
      text = <<~ANS
        [INTENT] IDENTIFICATION
        [DOCS]
        [Manual Orono, Transformadores.pdf]
        [RESUMEN]
        x
        [RIESGOS]
        ok
        [SECCIONES]
        ## Uno | Manual Orono
        body
        [MENU]
        1 | Riesgos | __riesgos__
        2 | Uno | __sec_1__
        3 | Nueva consulta | __new_query__
      ANS
      f = FacetedAnswer.parse(text)
      assert_equal [ "Manual Orono", "Transformadores.pdf" ], f.docs
    end

    test "riesgos_empty? detects the '— sin riesgos' sentinel phrase" do
      text = INSTALL_SAMPLE.sub(
        /\[RIESGOS\].*?\[SECCIONES\]/m,
        "[RIESGOS]\n— sin riesgos específicos documentados para esta consulta.\n[SECCIONES]"
      )
      f = FacetedAnswer.parse(text)
      assert f.riesgos_empty?
    end

    test "EMERGENCY intent parses with empty menu/sections and skips multi-doc banner" do
      text = <<~ANS
        [INTENT] EMERGENCY
        [DOCS]
        []
        [RESUMEN]
        Protocolo de rescate inmediato: detener y bloquear. Evacuar.
        [RIESGOS]
        🛑 Corte total de energía.
        [SECCIONES]
        (—)
        [MENU]
        (—)
      ANS
      f = FacetedAnswer.parse(text)
      assert f.emergency?
      assert_empty f.menu
      assert_empty f.sections
      msg = f.to_whatsapp_first_message(locale: :es)
      assert_match(/Protocolo de rescate/, msg)
      assert_no_match(/Fuentes consultadas/, msg)
      assert_no_match(/Opciones:/, msg)
    end

    test "plain-text fallback when no labels are present" do
      plain = "This is a legacy answer without any labels."
      f     = FacetedAnswer.parse(plain)
      assert_equal :identification, f.intent
      assert f.legacy?
      msg = f.to_whatsapp_first_message(locale: :es)
      assert_match(/This is a legacy answer/, msg)
    end

    test "blank text yields an empty legacy fallback" do
      f = FacetedAnswer.parse("   ")
      assert f.legacy?
      assert_empty f.sections
    end

    test "unknown intent token falls back to :identification" do
      text = INSTALL_SAMPLE.sub("[INTENT] INSTALLATION", "[INTENT] BOGUS")
      assert_equal :identification, FacetedAnswer.parse(text).intent
    end

    test "round-trip via to_cache_hash / from_cache preserves structure" do
      original = FacetedAnswer.parse(INSTALL_SAMPLE)
      restored = FacetedAnswer.from_cache(original.to_cache_hash)

      assert_equal original.intent, restored.intent
      assert_equal original.docs, restored.docs
      assert_equal original.resumen, restored.resumen
      assert_equal original.riesgos, restored.riesgos
      assert_equal original.sections.pluck(:label), restored.sections.pluck(:label)
      assert_equal original.menu, restored.menu
    end

    # --- render -------------------------------------------------------------

    test "to_whatsapp_first_message shows multi-doc banner when docs.size >= 2" do
      msg = FacetedAnswer.parse(INSTALL_SAMPLE).to_whatsapp_first_message(locale: :es)
      assert_match(/📚 \*Fuentes consultadas:\* Manual Orono A1, Transformadores\.pdf/, msg)
      assert_match(/Manual Orono A1/, msg)
      # 1 risks slot + 4 sections + 2 listing slots → 7 rows. Legacy new-query row removed.
      assert_match(/^1 - Riesgos$/, msg)
      assert_no_match(/Nueva consulta/, msg)
      assert_match(/^6 - Archivos recientes consultados$/, msg)
      assert_match(/^7 - Todos los archivos$/, msg)
      assert_no_match(/^\d - regresar$/, msg)
    end

    test "to_whatsapp_first_message omits banner for single-doc answers" do
      single = INSTALL_SAMPLE.sub(/\[DOCS\]\n\[.*?\]\n/, "[DOCS]\n[\"Manual Orono A1\"]\n")
      msg    = FacetedAnswer.parse(single).to_whatsapp_first_message(locale: :es)
      assert_no_match(/Fuentes consultadas/, msg)
    end

    test "to_section_message composes header with section sources" do
      msg = FacetedAnswer.parse(INSTALL_SAMPLE).to_section_message(:sec_2, locale: :es)
      assert_match(/\*Componentes · Manual Orono A1, Transformadores\.pdf\*/, msg)
      assert_match(/Transformador 220\/24V/, msg)
      assert_no_match(/^3 - Componentes$/, msg)
      assert_match(/^1 - Riesgos$/, msg)
      # File-listing slots remain available from inside a section view.
      assert_match(/Archivos recientes consultados/, msg)
      assert_match(/Todos los archivos/, msg)
    end

    test "to_section_message falls back to multiline header when combined is too long" do
      long_src = "Nombre de documento extremadamente largo que nunca cabe en una línea"
      text = INSTALL_SAMPLE.sub(
        /## Consideraciones iniciales \| Manual Orono A1/,
        "## Consideraciones iniciales | #{long_src}"
      )
      msg = FacetedAnswer.parse(text).to_section_message(:sec_1, locale: :es)
      assert_match(/^\*Consideraciones iniciales\*$/, msg)
      assert_match(/\(fuentes: \*#{Regexp.escape(long_src)}\*\)/, msg)
    end

    test "to_section_message for :riesgos uses the docs_banner sources" do
      msg = FacetedAnswer.parse(INSTALL_SAMPLE).to_section_message(:riesgos, locale: :es)
      assert_match(/\*Riesgos/, msg)
      assert_match(/LOTO obligatorio/, msg)
    end

    test "to_section_message returns empty string when the section is empty" do
      text = INSTALL_SAMPLE.sub(
        /## Verificación \| Manual Orono A1\nPruebas de recorrido \+ inspección de seguridad\./,
        "## Verificación | Manual Orono A1\n(—)"
      )
      msg = FacetedAnswer.parse(text).to_section_message(:sec_4, locale: :es)
      assert_equal "", msg
    end

    test "legacy prompt output ([PARÁMETROS]+[DETALLE]) is synthesized into sections" do
      legacy = <<~ANS
        [INTENT] IDENTIFICATION
        [RESUMEN]
        Placa principal.
        [RIESGOS]
        (—)
        [PARÁMETROS]
        ① 24VDC
        [DETALLE]
        Contenido extendido.
        [MENU]
        1 | Riesgos | __riesgos__
        2 | Parámetros | parametros
        3 | Detalle | detalle
        4 | Nueva consulta | __new_query__
      ANS
      f = FacetedAnswer.parse(legacy)
      labels = f.sections.pluck(:label)
      assert_includes labels, "Parámetros"
      assert_includes labels, "Detalle"
      # Menu still resolves deterministically for the section kinds.
      assert_equal :section,   f.menu[1][:kind]
      # Legacy __new_query__ is stripped; list slots appended in its place.
      assert_not f.menu.any? { |m| m[:kind] == :new_query }
      assert_equal :list_recent, f.menu[-2][:kind]
      assert_equal :list_all,    f.menu[-1][:kind]
    end

    test "list slots are localized at render time (en)" do
      msg = FacetedAnswer.parse(INSTALL_SAMPLE).to_whatsapp_first_message(locale: :en)
      assert_match(/^6 - Recently consulted files$/, msg)
      assert_match(/^7 - All files$/, msg)
    end

    test "menu separates the file-listing slots from query options with a blank line" do
      msg = FacetedAnswer.parse(INSTALL_SAMPLE).to_whatsapp_first_message(locale: :es)
      # The last dynamic section is followed by a blank line before the file-list slots.
      assert_match(/^5 - Verificación\n\n6 - Archivos recientes consultados$/m, msg)
      # The two list rows themselves stay tight (no extra blank line between them).
      assert_match(/^6 - Archivos recientes consultados\n7 - Todos los archivos$/m, msg)
    end

    test "section message also separates list slots with a blank line" do
      msg = FacetedAnswer.parse(INSTALL_SAMPLE).to_section_message(:sec_2, locale: :es)
      # The section view excludes "3 - Componentes"; the boundary moves but the
      # rule still holds: blank line BEFORE the first list slot.
      assert_match(/\n\n6 - Archivos recientes consultados\n7 - Todos los archivos/m, msg)
    end

    test "from_cache preserves list slots without re-appending duplicates" do
      original = FacetedAnswer.parse(INSTALL_SAMPLE)
      restored = FacetedAnswer.from_cache(original.to_cache_hash)
      assert_equal original.menu.length, restored.menu.length
      assert_equal :list_recent, restored.menu[-2][:kind]
      assert_equal :list_all,    restored.menu[-1][:kind]
    end
  end
end
