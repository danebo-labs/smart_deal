# frozen_string_literal: true

require "test_helper"

module Rag
  class WhatsappFollowupClassifierTest < ActiveSupport::TestCase
    # Cached payload fixture matching Rag::WhatsappAnswerCache schema.
    def cached(intent: :identification, facets: default_facets, menu: default_menu, question: "que es la PCB?")
      {
        question:         question,
        question_hash:    "deadbeefdeadbeef",
        faceted:          { intent: intent, facets: facets, menu: menu, entities: [ "Orona PCB Mainboard" ] },
        citations:        [],
        doc_refs:         [],
        locale:           :es,
        entity_signature: "sig1234sig1",
        intent:           intent,
        generated_at:     Time.current.to_i
      }
    end

    def default_facets
      {
        resumen:    "Orona PCB — placa principal.",
        riesgos:    "⚠️ LOTO requerido.",
        parametros: "① 24VDC",
        secciones:  "- Diagnóstico",
        detalle:    "Detalle técnico."
      }
    end

    def default_menu
      [
        { n: 1, label: "Riesgos",    facet_key: :riesgos },
        { n: 2, label: "Parámetros", facet_key: :parametros },
        { n: 3, label: "Secciones",  facet_key: :secciones },
        { n: 4, label: "Detalle",    facet_key: :detalle }
      ]
    end

    def session_with_assistant(content)
      Struct.new(:history) do
        def recent_history_for_prompt(turns: 3)
          history.last(turns)
        end
      end.new([ { role: "assistant", content: content } ])
    end

    # --- deterministic navigation routes (allowlist) -------------------------

    test "number token resolves via cached menu → :facet_hit" do
      d = WhatsappFollowupClassifier.classify(message: "1", cached: cached, conv_session: nil, locale: :es)
      assert_equal :facet_hit, d.route
      assert_equal :riesgos, d.facet_key
      assert_equal :deterministic_token, d.reason
    end

    test "literal facet keyword with accents/casing is normalized → :facet_hit" do
      d = WhatsappFollowupClassifier.classify(message: "  RIESGOS ", cached: cached, conv_session: nil, locale: :es)
      assert_equal :facet_hit, d.route
      assert_equal :riesgos, d.facet_key
    end

    test "deterministic number on empty facet → :new_query reason=:empty_facet_reconsult" do
      empty_params = cached(facets: default_facets.merge(parametros: "(—)"))
      d = WhatsappFollowupClassifier.classify(message: "2", cached: empty_params, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :empty_facet_reconsult, d.reason
    end

    test "deterministic facet word on empty facet → :new_query reason=:empty_facet_reconsult" do
      empty_riesgos = cached(facets: default_facets.merge(riesgos: "(—)"))
      d = WhatsappFollowupClassifier.classify(message: "riesgos", cached: empty_riesgos, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :empty_facet_reconsult, d.reason
    end

    test "menu token with empty cache → :no_context_help" do
      d = WhatsappFollowupClassifier.classify(message: "1", cached: nil, conv_session: nil, locale: :es)
      assert_equal :no_context_help, d.route
      assert_equal :menu_without_cache, d.reason
    end

    test "reset token → :reset_ack reason=:user_reset" do
      d = WhatsappFollowupClassifier.classify(message: "nuevo", cached: cached, conv_session: nil, locale: :es)
      assert_equal :reset_ack, d.route
      assert_equal :user_reset, d.reason
    end

    test "'inicio' is a reset alias → :reset_ack" do
      %w[inicio start home].each do |token|
        d = WhatsappFollowupClassifier.classify(message: token, cached: cached, conv_session: nil, locale: :es)
        assert_equal :reset_ack, d.route, "#{token} must reset"
      end
    end

    test "numeric '6' alias → :reset_ack (home slot in the nav row)" do
      d = WhatsappFollowupClassifier.classify(message: "6", cached: cached, conv_session: nil, locale: :es)
      assert_equal :reset_ack, d.route
      assert_equal :user_reset, d.reason
    end

    test "numeric '5' alias with cache → :show_menu (regresar slot)" do
      d = WhatsappFollowupClassifier.classify(message: "5", cached: cached, conv_session: nil, locale: :es)
      assert_equal :show_menu, d.route
      assert_equal :menu_redraw, d.reason
    end

    test "numeric '5' alias without cache → :no_context_help" do
      d = WhatsappFollowupClassifier.classify(message: "5", cached: nil, conv_session: nil, locale: :es)
      assert_equal :no_context_help, d.route
    end

    test "menu redraw token with active cache → :show_menu reason=:menu_redraw" do
      d = WhatsappFollowupClassifier.classify(message: "menu", cached: cached, conv_session: nil, locale: :es)
      assert_equal :show_menu, d.route
      assert_equal :menu_redraw, d.reason
    end

    test "'resumen' / 'summary' aliases redraw the menu from cache" do
      %w[resumen summary ficha overview].each do |token|
        d = WhatsappFollowupClassifier.classify(message: token, cached: cached, conv_session: nil, locale: :es)
        assert_equal :show_menu, d.route, "#{token} must redraw"
        assert_equal :menu_redraw, d.reason
      end
    end

    test "no cache at all → :new_query reason=:no_cache" do
      d = WhatsappFollowupClassifier.classify(message: "cualquier pregunta", cached: nil, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :no_cache, d.reason
    end

    # --- "más" via history ---------------------------------------------------

    test "'más' tras turno assistant '📏 Parámetros — …' → :facet_hit :parametros" do
      sess = session_with_assistant("📏 Parámetros — 24VDC")
      d = WhatsappFollowupClassifier.classify(message: "más", cached: cached, conv_session: sess, locale: :es)
      assert_equal :facet_hit, d.route
      assert_equal :parametros, d.facet_key
      assert_equal :deterministic_mas_last_facet, d.reason
    end

    test "'más' on empty last facet → :new_query reason=:empty_facet_reconsult" do
      sess  = session_with_assistant("📏 Parámetros — 24VDC")
      empty = cached(facets: default_facets.merge(parametros: "(—)"))
      d = WhatsappFollowupClassifier.classify(message: "más", cached: empty, conv_session: sess, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :empty_facet_reconsult, d.reason
    end

    # --- safety policy: free text always → :new_query ------------------------

    test "single domain keyword 'voltaje' → :new_query (NOT served from cache)" do
      d = WhatsappFollowupClassifier.classify(message: "voltaje", cached: cached, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :content_query, d.reason
      assert_nil d.matched_token, "synonym map removed; matched_token must always be nil"
    end

    test "short field-style queries without '?' all go to :new_query" do
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
        assert_equal :content_query, d.reason, "#{msg.inspect} reason"
      end
    end

    test "free text containing a navigation word in a sentence is NOT a nav token" do
      # Matching is on the FULLY normalized token; substring presence
      # ("menu" inside a sentence) must not redraw the menu.
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

    test "'rescate' (was strong_intent_shift) now falls through as content_query" do
      d = WhatsappFollowupClassifier.classify(
        message: "procedimiento de rescate", cached: cached, conv_session: nil, locale: :es
      )
      assert_equal :new_query, d.route
      assert_equal :content_query, d.reason
    end
  end
end
