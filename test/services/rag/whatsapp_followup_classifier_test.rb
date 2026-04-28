# frozen_string_literal: true

require "test_helper"

module Rag
  class WhatsappFollowupClassifierTest < ActiveSupport::TestCase
    # Cached payload fixture matching the new v4 Rag::WhatsappAnswerCache schema.
    def cached(intent: :installation, sections: default_sections, menu: default_menu,
               riesgos: "LOTO obligatorio.", question: "como instalo orono a1")
      {
        question:         question,
        question_hash:    "deadbeefdeadbeef",
        structured:       {
          intent:   intent,
          docs:     [ "Manual Orono A1", "Transformadores.pdf" ],
          resumen:  "Instalación Orono A1 — 4 etapas.",
          riesgos:  riesgos,
          sections: sections,
          menu:     menu,
          raw:      "[INTENT] INSTALLATION\n"
        },
        citations:        [],
        doc_refs:         [],
        locale:           :es,
        entity_signature: "sig1234sig1",
        intent:           intent,
        generated_at:     Time.current.to_i
      }
    end

    def default_sections
      [
        { n: 1, key: :sec_1, label: "Consideraciones iniciales", sources: [ "Manual Orono A1" ], body: "Validar plomada." },
        { n: 2, key: :sec_2, label: "Componentes",               sources: [ "Manual Orono A1", "Transformadores.pdf" ], body: "① Contrapeso." },
        { n: 3, key: :sec_3, label: "Paso a paso",               sources: [ "Manual Orono A1" ], body: "Pasos 1..n." },
        { n: 4, key: :sec_4, label: "Verificación",              sources: [ "Manual Orono A1" ], body: "Pruebas." }
      ]
    end

    def default_menu
      [
        { n: 1, label: "⚠️ Riesgos",                kind: :riesgos,     section_key: :riesgos },
        { n: 2, label: "Consideraciones iniciales", kind: :section,     section_key: :sec_1 },
        { n: 3, label: "Componentes",               kind: :section,     section_key: :sec_2 },
        { n: 4, label: "Paso a paso",               kind: :section,     section_key: :sec_3 },
        { n: 5, label: "Verificación",              kind: :section,     section_key: :sec_4 },
        { n: 6, label: "list_recent",               kind: :list_recent, section_key: nil },
        { n: 7, label: "list_all",                  kind: :list_all,    section_key: nil }
      ]
    end

    # --- deterministic navigation --------------------------------------------

    test "digit 1 resolves to pinned :riesgos via cached menu" do
      d = WhatsappFollowupClassifier.classify(message: "1", cached: cached, conv_session: nil, locale: :es)
      assert_equal :section_hit, d.route
      assert_equal :riesgos, d.section_key
      assert_equal :deterministic_digit, d.reason
    end

    test "digit in the middle of the menu maps to the matching section key" do
      d = WhatsappFollowupClassifier.classify(message: "3", cached: cached, conv_session: nil, locale: :es)
      assert_equal :section_hit, d.route
      assert_equal :sec_2, d.section_key
    end

    test "list_recent slot routes to :show_doc_list with source :recent" do
      d = WhatsappFollowupClassifier.classify(message: "6", cached: cached, conv_session: nil, locale: :es)
      assert_equal :show_doc_list, d.route
      assert_equal :recent, d.source
      assert_equal :menu_list_recent, d.reason
    end

    test "list_all slot routes to :show_doc_list with source :all" do
      d = WhatsappFollowupClassifier.classify(message: "7", cached: cached, conv_session: nil, locale: :es)
      assert_equal :show_doc_list, d.route
      assert_equal :all, d.source
      assert_equal :menu_list_all, d.reason
    end

    test "legacy :new_query slot still triggers :user_reset (cache rollover)" do
      legacy_menu = default_menu.first(5) + [
        { n: 6, label: "🔄 Nueva consulta", kind: :new_query, section_key: nil }
      ]
      legacy_cached = cached(menu: legacy_menu)
      d = WhatsappFollowupClassifier.classify(message: "6", cached: legacy_cached, conv_session: nil, locale: :es)
      assert_equal :user_reset, d.route
      assert_equal :user_reset, d.reason
    end

    test "digit outside cached menu range → :no_context_help" do
      d = WhatsappFollowupClassifier.classify(message: "9", cached: cached, conv_session: nil, locale: :es)
      assert_equal :no_context_help, d.route
      assert_equal :digit_out_of_range, d.reason
    end

    test "tapping an empty section triggers :empty_section_reconsult" do
      empty = cached(sections: default_sections.tap { |s| s[1] = s[1].merge(body: "(—)") })
      d = WhatsappFollowupClassifier.classify(message: "3", cached: empty, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :empty_section_reconsult, d.reason
      assert_equal :sec_2, d.section_key
    end

    test "tapping an empty :riesgos triggers :empty_section_reconsult" do
      empty = cached(riesgos: "— sin riesgos específicos documentados para esta consulta.")
      d = WhatsappFollowupClassifier.classify(message: "1", cached: empty, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :empty_section_reconsult, d.reason
      assert_equal :riesgos, d.section_key
    end

    # --- reset tokens --------------------------------------------------------

    test "'inicio' is :reset_ack_with_picker (keeps the 1=recientes / 2=existentes flow)" do
      %w[inicio start home].each do |t|
        d = WhatsappFollowupClassifier.classify(message: t, cached: cached, conv_session: nil, locale: :es)
        assert_equal :reset_ack_with_picker, d.route, "#{t} must go through the picker"
        assert_equal :user_reset_with_picker, d.reason
      end
    end

    test "'nuevo' / 'nueva' / 'new' / 'reset' are :user_reset (no picker)" do
      %w[nuevo nueva new reset].each do |t|
        d = WhatsappFollowupClassifier.classify(message: t, cached: cached, conv_session: nil, locale: :es)
        assert_equal :user_reset, d.route, "#{t} must reset without picker"
        assert_equal :user_reset, d.reason
      end
    end

    # --- strict policy: NO redraw tokens, NO 'mas' shortcut ------------------

    test "redraw-style words go to :new_query (full menu is always rendered as footer)" do
      %w[menu volver regresar back atras resumen ficha overview summary].each do |t|
        d = WhatsappFollowupClassifier.classify(message: t, cached: cached, conv_session: nil, locale: :es)
        assert_equal :new_query, d.route, "#{t} must NOT redraw — strict mode treats it as a content query"
        assert_equal :content_query, d.reason
      end
    end

    test "'mas' alone is just a content query (no history shortcut anymore)" do
      d = WhatsappFollowupClassifier.classify(message: "mas", cached: cached, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :content_query, d.reason
    end

    test "no cache + non-reset word → :new_query (no_cache)" do
      d = WhatsappFollowupClassifier.classify(message: "menu", cached: nil, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :no_cache, d.reason
    end

    # --- safety policy: free text always → :new_query ------------------------

    test "single domain keyword 'voltaje' is ALWAYS :new_query (not served from cache)" do
      d = WhatsappFollowupClassifier.classify(message: "voltaje", cached: cached, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :content_query, d.reason
    end

    test "short field-style queries all go to :new_query" do
      [
        "voltaje componente",
        "torque tornillo m8",
        "pasos cambio freno",
        "riesgo abrir tablero",
        "puedo desconectar fase",
        "como diagnosticar fallo placa"
      ].each do |msg|
        d = WhatsappFollowupClassifier.classify(message: msg, cached: cached, conv_session: nil, locale: :es)
        assert_equal :new_query, d.route, "#{msg.inspect} must go to RAG"
        assert_equal :content_query, d.reason
      end
    end

    test "nav word inside a sentence is NOT a nav token" do
      d = WhatsappFollowupClassifier.classify(message: "que opciones del menu hay", cached: cached, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :content_query, d.reason
    end

    test "long free-text query → :new_query reason=:content_query" do
      long = "explícame con detalle el sistema eléctrico, los fusibles y la topología en redundancia"
      d = WhatsappFollowupClassifier.classify(message: long, cached: cached, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :content_query, d.reason
    end

    test "literal 'riesgos' word is NOT a shortcut anymore (safety: only digits resolve)" do
      d = WhatsappFollowupClassifier.classify(message: "riesgos", cached: cached, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :content_query, d.reason
    end
  end
end
