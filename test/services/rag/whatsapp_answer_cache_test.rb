# frozen_string_literal: true

require "test_helper"

module Rag
  class WhatsappAnswerCacheTest < ActiveSupport::TestCase
    def stub_shared_enabled(enabled)
      orig = SharedSession::ENABLED
      SharedSession.send(:remove_const, :ENABLED)
      SharedSession.const_set(:ENABLED, enabled)
      yield
    ensure
      SharedSession.send(:remove_const, :ENABLED)
      SharedSession.const_set(:ENABLED, orig)
    end

    setup do
      @previous_cache = Rails.cache
      Rails.cache     = ActiveSupport::Cache::MemoryStore.new
      @to             = "whatsapp:+56912345678"
      @structured     = {
        intent:   :identification,
        docs:     [ "Manual Orono A1" ],
        resumen:  "Orona PCB — placa principal.",
        riesgos:  "LOTO requerido.",
        sections: [ { n: 1, key: :sec_1, label: "Descripción", sources: [ "Manual Orono A1" ], body: "Placa principal." } ],
        menu:     [
          { n: 1, label: "Riesgos", kind: :riesgos, section_key: :riesgos },
          { n: 2, label: "Descripción", kind: :section, section_key: :sec_1 },
          { n: 3, label: "Nueva consulta", kind: :new_query, section_key: nil }
        ],
        raw:      "[INTENT] IDENTIFICATION\n"
      }
      @base_value = {
        question:         "que es la PCB?",
        question_hash:    WhatsappAnswerCache.question_hash("que es la PCB?"),
        structured:       @structured,
        citations:        [],
        doc_refs:         [],
        locale:           :es,
        entity_signature: "abc123abc123",
        intent:           :identification,
        generated_at:     nil
      }
    end

    teardown do
      Rails.cache = @previous_cache
    end

    test "write + read round-trip returns the payload" do
      assert WhatsappAnswerCache.write(@to, @base_value)

      value = WhatsappAnswerCache.read(@to)
      assert_not_nil value
      assert_equal :identification, value[:intent]
      assert_equal "que es la PCB?", value[:question]
      assert value[:generated_at].is_a?(Integer), "generated_at should be stamped on write"
      assert_equal [ "Manual Orono A1" ], value[:structured][:docs]
      assert_equal 3, value[:structured][:menu].length
    end

    test "read miss returns nil" do
      assert_nil WhatsappAnswerCache.read(@to)
    end

    test "EMERGENCY intent is never cached" do
      emergency = @base_value.merge(intent: :emergency)
      assert_not WhatsappAnswerCache.write(@to, emergency), "write should skip for emergency"
      assert_nil WhatsappAnswerCache.read(@to), "no value should be stored"
    end

    test "entity drift invalidates and returns nil when shared mode is off" do
      stub_shared_enabled(false) do
        WhatsappAnswerCache.write(@to, @base_value)

        stale_session = Struct.new(:active_entities).new({ "orona_pcb" => {} })
        fresh_session = Struct.new(:active_entities).new({ "otis_gen3" => {} })

        assert_nil WhatsappAnswerCache.read(@to, conv_session: stale_session)

        WhatsappAnswerCache.write(@to, @base_value)
        assert_not_nil WhatsappAnswerCache.read(@to)

        assert_nil WhatsappAnswerCache.read(@to, conv_session: fresh_session)
        assert_nil Rails.cache.read(WhatsappAnswerCache.key(@to))
      end
    end

    test "entity drift is IGNORED when SharedSession::ENABLED is true" do
      stub_shared_enabled(true) do
        WhatsappAnswerCache.write(@to, @base_value)

        drifted_session = Struct.new(:active_entities).new({ "otis_gen3" => {} })

        value = WhatsappAnswerCache.read(@to, conv_session: drifted_session)
        assert_not_nil value, "shared mode must serve the cached answer despite entity drift"
        assert_equal :identification, value[:intent]
        assert_not_nil Rails.cache.read(WhatsappAnswerCache.key(@to)), "shared mode must NOT purge on drift"
      end
    end

    test "matching entity signature serves from cache" do
      session = Struct.new(:active_entities).new({ "orona_pcb" => {} })
      sig     = WhatsappAnswerCache.entity_signature_for(session)
      value   = @base_value.merge(entity_signature: sig)

      WhatsappAnswerCache.write(@to, value)
      assert_not_nil WhatsappAnswerCache.read(@to, conv_session: session)
    end

    test "corrupt payload is rescued and invalidated" do
      Rails.cache.write(WhatsappAnswerCache.key(@to), "not a hash")
      assert_nil WhatsappAnswerCache.read(@to)
      assert_nil Rails.cache.read(WhatsappAnswerCache.key(@to)), "corrupt entry should be purged"
    end

    test "schema drift (missing keys) is treated as corrupt" do
      Rails.cache.write(WhatsappAnswerCache.key(@to), { foo: "bar" })
      assert_nil WhatsappAnswerCache.read(@to)
    end

    test "v3 payload (with faceted + document_label) is treated as corrupt and purged" do
      v3_payload = {
        question:         "q",
        question_hash:    "q1",
        faceted:          { intent: :identification, facets: {}, menu: [], raw: "" },
        citations:        [],
        doc_refs:         [],
        locale:           :es,
        entity_signature: "sig",
        intent:           :identification,
        generated_at:     Time.current.to_i,
        document_label:   "PCB Orona"
      }
      Rails.cache.write(WhatsappAnswerCache.key(@to), v3_payload)
      assert_nil WhatsappAnswerCache.read(@to), "v3 schema must no longer satisfy v4 SCHEMA_KEYS"
      assert_nil Rails.cache.read(WhatsappAnswerCache.key(@to))
    end

    test "cache key carries the v5 version prefix" do
      assert_match %r{\Arag_wa_faceted/v5/}, WhatsappAnswerCache.key(@to)
    end

    test "invalidate purges the key" do
      WhatsappAnswerCache.write(@to, @base_value)
      assert_not_nil Rails.cache.read(WhatsappAnswerCache.key(@to))

      WhatsappAnswerCache.invalidate(@to)
      assert_nil Rails.cache.read(WhatsappAnswerCache.key(@to))
    end

    test "entity_signature is stable for same keys regardless of order" do
      a = Struct.new(:active_entities).new({ "b" => 1, "a" => 2 })
      b = Struct.new(:active_entities).new({ "a" => 2, "b" => 1 })
      assert_equal WhatsappAnswerCache.entity_signature_for(a),
                   WhatsappAnswerCache.entity_signature_for(b)
    end

    test "question_hash is deterministic and case/whitespace-insensitive" do
      h1 = WhatsappAnswerCache.question_hash("Qué es la PCB?")
      h2 = WhatsappAnswerCache.question_hash("  qué es la pcb?  ")
      assert_equal h1, h2
      assert_equal 16, h1.length
    end
  end
end
