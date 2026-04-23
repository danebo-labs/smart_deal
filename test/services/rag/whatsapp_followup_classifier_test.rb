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

    setup do
      @orig_nano = ENV["WA_NANO_CLASSIFIER_ENABLED"]
      ENV["WA_NANO_CLASSIFIER_ENABLED"] = "false"
    end

    teardown do
      ENV["WA_NANO_CLASSIFIER_ENABLED"] = @orig_nano
    end

    # --- deterministic routes ---

    test "number token resolves via cached menu → :facet_hit" do
      d = WhatsappFollowupClassifier.classify(message: "1", cached: cached, conv_session: nil, locale: :es)
      assert_equal :facet_hit, d.route
      assert_equal :riesgos, d.facet_key
      assert_equal :deterministic_token, d.reason
    end

    test "literal keyword with accents/casing is normalized → :facet_hit" do
      d = WhatsappFollowupClassifier.classify(message: "  RIESGOS ", cached: cached, conv_session: nil, locale: :es)
      assert_equal :facet_hit, d.route
      assert_equal :riesgos, d.facet_key
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

    # --- synonym map ---

    test "'voltaje' routes to :parametros when facet is populated" do
      d = WhatsappFollowupClassifier.classify(message: "voltaje", cached: cached, conv_session: nil, locale: :es)
      assert_equal :facet_hit, d.route
      assert_equal :parametros, d.facet_key
      assert_equal :synonym_match, d.reason
    end

    test "synonym match populates Decision#matched_token for downstream hoist" do
      d = WhatsappFollowupClassifier.classify(message: "¿y el voltaje?", cached: cached, conv_session: nil, locale: :es)
      assert_equal :synonym_match, d.reason
      assert_equal "voltaje", d.matched_token
    end

    test "synonym is ignored when facet is empty → falls through to nano/fallback" do
      empty_params = cached(facets: default_facets.merge(parametros: "(—)"))
      d = WhatsappFollowupClassifier.classify(message: "voltaje", cached: empty_params, conv_session: nil, locale: :es)
      # nano disabled in setup → nano_disabled_fallback
      assert_equal :new_query, d.route
      assert_equal :nano_disabled_fallback, d.reason
    end

    # --- "más" via history ---

    test "'más' tras turno assistant '📏 Parámetros — …' → :facet_hit :parametros" do
      sess = session_with_assistant("📏 Parámetros — 24VDC")
      d = WhatsappFollowupClassifier.classify(message: "más", cached: cached, conv_session: sess, locale: :es)
      assert_equal :facet_hit, d.route
      assert_equal :parametros, d.facet_key
      assert_equal :deterministic_mas_last_facet, d.reason
    end

    # --- strong intent shift ---

    test "strong intent phrase 'procedimiento de rescate' → :new_query reason=:strong_intent_shift" do
      d = WhatsappFollowupClassifier.classify(
        message: "procedimiento de rescate", cached: cached, conv_session: nil, locale: :es
      )
      assert_equal :new_query, d.route
      assert_equal :strong_intent_shift, d.reason
    end

    test "strong intent phrase is suppressed when cached intent is emergency" do
      d = WhatsappFollowupClassifier.classify(
        message: "rescate", cached: cached(intent: :emergency), conv_session: nil, locale: :es
      )
      # Falls through past step 3; 'rescate' isn't a menu token nor in SYNONYM_MAP for a non-empty facet.
      # Nano disabled → nano_disabled_fallback (short message, not > 120 chars).
      assert_equal :new_query, d.route
      assert_equal :nano_disabled_fallback, d.reason
    end

    # --- length heuristic ---

    test "message > 120 chars → :new_query reason=:message_too_long" do
      long = "a" * 130
      d = WhatsappFollowupClassifier.classify(message: long, cached: cached, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :message_too_long, d.reason
    end

    # --- nano disabled + enabled ---

    test "short ambiguous message + nano disabled → :nano_disabled_fallback" do
      d = WhatsappFollowupClassifier.classify(message: "eeh", cached: cached, conv_session: nil, locale: :es)
      assert_equal :new_query, d.route
      assert_equal :nano_disabled_fallback, d.reason
    end

    test "nano returns facet_hit with confidence over threshold" do
      ENV["WA_NANO_CLASSIFIER_ENABLED"] = "true"
      with_stubbed_ai('{"route":"facet_hit","facet_key":"parametros","confidence":0.9}') do
        d = WhatsappFollowupClassifier.classify(message: "hmm", cached: cached, conv_session: nil, locale: :es)
        assert_equal :facet_hit, d.route
        assert_equal :parametros, d.facet_key
        assert_equal :nano_decision, d.reason
      end
    end

    test "nano low confidence → :new_query reason=:nano_low_confidence_fallback" do
      ENV["WA_NANO_CLASSIFIER_ENABLED"] = "true"
      with_stubbed_ai('{"route":"facet_hit","facet_key":"parametros","confidence":0.5}') do
        d = WhatsappFollowupClassifier.classify(message: "hmm", cached: cached, conv_session: nil, locale: :es)
        assert_equal :new_query, d.route
        assert_equal :nano_low_confidence_fallback, d.reason
      end
    end

    test "nano requests empty facet → fallback to :detalle" do
      ENV["WA_NANO_CLASSIFIER_ENABLED"] = "true"
      empty_params = cached(facets: default_facets.merge(parametros: "(—)"))
      with_stubbed_ai('{"route":"facet_hit","facet_key":"parametros","confidence":0.9}') do
        d = WhatsappFollowupClassifier.classify(message: "hmm", cached: empty_params, conv_session: nil, locale: :es)
        assert_equal :facet_hit, d.route
        assert_equal :detalle, d.facet_key
        assert_equal :empty_facet_fallback_detalle, d.reason
      end
    end

    test "nano raises → returns nil and falls through to :nano_disabled_fallback" do
      ENV["WA_NANO_CLASSIFIER_ENABLED"] = "true"
      with_stubbed_ai(-> { raise "boom" }) do
        d = WhatsappFollowupClassifier.classify(message: "hmm", cached: cached, conv_session: nil, locale: :es)
        assert_equal :new_query, d.route
        assert_equal :nano_disabled_fallback, d.reason
      end
    end

    test "nano parse error → falls through to :nano_disabled_fallback" do
      ENV["WA_NANO_CLASSIFIER_ENABLED"] = "true"
      with_stubbed_ai("not json") do
        d = WhatsappFollowupClassifier.classify(message: "hmm", cached: cached, conv_session: nil, locale: :es)
        assert_equal :new_query, d.route
        assert_equal :nano_disabled_fallback, d.reason
      end
    end

    private

    # Stubs AiProvider#query. Accepts a static string (returned as-is) or a proc
    # (called each invocation). Kept Mocha-free for parity with the repo style.
    def with_stubbed_ai(response)
      original = AiProvider.instance_method(:query)
      AiProvider.define_method(:query) do |*_args, **_opts|
        response.respond_to?(:call) ? response.call : response
      end
      yield
    ensure
      AiProvider.define_method(:query, original)
    end
  end
end
