# frozen_string_literal: true

require "test_helper"

module Rag
  class DocumentOverviewResponderTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rails.cache = @previous_cache
    end

    def make_account
      Account.create!(display_name: "Responder Co", slug: "responder-#{SecureRandom.hex(4)}")
    end

    def make_kb_document(account, display_name: "Manual", aliases: [])
      KbDocument.create!(account: account, s3_key: "uploads/#{SecureRandom.hex(4)}.pdf",
                          display_name: display_name, aliases: aliases)
    end

    def session_with(entities)
      Struct.new(:active_entities).new(entities)
    end

    def entity_for(kb_document, aliases: [], source: "user_pin", added_at: Time.current.iso8601)
      {
        "canonical_name" => kb_document.display_name,
        "kb_document_id" => kb_document.id,
        "aliases"        => aliases,
        "source"         => source,
        "added_at"       => added_at
      }
    end

    def write_overview_cache(account, kb_document, sections:)
      Rag::DocumentOverviewCache.write(
        account_id: account.id, kb_document_id: kb_document.id,
        value: { sections: sections, chunk_count: sections.size, source: "manifest" }
      )
    end

    test "build returns nil with zero pins" do
      account = make_account

      assert_nil DocumentOverviewResponder.build(question: "", account: account, conv_session: session_with({}))
    end

    test "build returns an instance with two pins and the autofilled (concatenated) question" do
      account = make_account
      doc1 = make_kb_document(account, display_name: "Manual A")
      doc2 = make_kb_document(account, display_name: "Manual B")
      session = session_with("Manual A" => entity_for(doc1), "Manual B" => entity_for(doc2))

      instance = DocumentOverviewResponder.build(
        question: "Manual A Manual B", account: account, conv_session: session
      )

      assert_instance_of DocumentOverviewResponder, instance
    end

    # V9: this used to pass because of an incidental `entities.size == 1` guard.
    # It must now pass because entities without source: "user_pin" are filtered
    # out, not because of any pin-count guard (there is none).
    test "build ignores entities whose source is not user_pin, even if their name matches" do
      account = make_account
      doc = make_kb_document(account, display_name: "Manual A")
      session = session_with("Manual A" => entity_for(doc, source: "citation_filename_fallback"))

      assert_nil DocumentOverviewResponder.build(question: "Manual A", account: account, conv_session: session)
    end

    test "build returns nil for a real question" do
      account = make_account
      doc = make_kb_document(account, display_name: "Manual A")
      session = session_with("Manual A" => entity_for(doc))

      assert_nil DocumentOverviewResponder.build(
        question: "¿cómo pruebo el cerrojo?", account: account, conv_session: session
      )
    end

    test "build returns an instance with one pin and the autofilled question" do
      account = make_account
      doc = make_kb_document(account, display_name: "Manual A")
      session = session_with("Manual A" => entity_for(doc))

      instance = DocumentOverviewResponder.build(question: "Manual A", account: account, conv_session: session)

      assert_instance_of DocumentOverviewResponder, instance
    end

    test "build returns nil when the pinned kb_document_id belongs to another account" do
      account = make_account
      other_account = make_account
      doc = make_kb_document(other_account, display_name: "Manual A")
      session = session_with("Manual A" => entity_for(doc))

      assert_nil DocumentOverviewResponder.build(question: "Manual A", account: account, conv_session: session)
    end

    test "build only resolves the 4 most recently pinned documents out of 5" do
      account = make_account
      docs = 5.times.map { |i| make_kb_document(account, display_name: "Manual #{i}") }
      base_time = 1.hour.ago
      entities = docs.each_with_index.to_h do |doc, i|
        [ doc.display_name, entity_for(doc, added_at: (base_time + i.seconds).iso8601) ]
      end
      session = session_with(entities)

      queries = []
      cb = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /SELECT.*kb_documents/i && payload[:name] != "SCHEMA" }
      instance = nil
      ActiveSupport::Notifications.subscribed(cb, "sql.active_record") do
        instance = DocumentOverviewResponder.build(question: "", account: account, conv_session: session)
      end

      assert_instance_of DocumentOverviewResponder, instance
      resolved_names = instance.instance_variable_get(:@kb_documents).map(&:display_name)
      assert_equal 4, resolved_names.size
      assert_not_includes resolved_names, "Manual 0" # oldest pin, evicted by MAX_OVERVIEW_DOCUMENTS
      assert_equal 1, queries.size, "kb_document_id resolution must run a single query, not N"
    end

    test "execute returns nil when the builder returns nil" do
      account = make_account
      doc = make_kb_document(account, display_name: "Manual A")

      assert_nil DocumentOverviewResponder.new(account: account, kb_documents: [ doc ]).execute
    end

    test "execute returns a deterministic hash on a cache hit" do
      account = make_account
      doc = make_kb_document(account, display_name: "Manual A")
      write_overview_cache(account, doc, sections: [ { label: "SEGURIDADES", first_page: 1, last_page: 3, chunk_count: 2 } ])

      result = DocumentOverviewResponder.new(account: account, kb_documents: [ doc ]).execute

      assert_equal false, result[:model_invoked]
      assert_equal [], result[:citations]
      assert_equal [], result[:retrieved_citations]
      assert_equal "deterministic_document_overview", result[:generation_mode]
      assert_equal "Manual A", result[:doc_refs].first["canonical_name"]
      assert_equal 1, result[:quick_replies].size
      assert_includes result[:answer], "SEGURIDADES"
      assert_includes result[:answer], "Documento: Manual A"
    end

    test "execute renders one Documento block per pinned document, with sections, and a single closing question" do
      account = make_account
      doc_a = make_kb_document(account, display_name: "Manual A")
      doc_b = make_kb_document(account, display_name: "Manual B")
      write_overview_cache(account, doc_a, sections: [ { label: "ELECTRICAL", first_page: 1, last_page: 5, chunk_count: 2 } ])
      write_overview_cache(account, doc_b, sections: [ { label: "CONTROLES", first_page: 1, last_page: 8, chunk_count: 2 } ])

      result = DocumentOverviewResponder.new(account: account, kb_documents: [ doc_a, doc_b ]).execute

      assert_includes result[:answer], "Documento: Manual A"
      assert_includes result[:answer], "ELECTRICAL"
      assert_includes result[:answer], "Documento: Manual B"
      assert_includes result[:answer], "CONTROLES"
      assert_equal 1, result[:answer].scan(I18n.t("rag.document_overview.closing_question")).size
      assert_equal 2, result[:doc_refs].size
    end

    test "execute renders only the hit when one of two pinned documents has no overview" do
      account = make_account
      doc_a = make_kb_document(account, display_name: "Manual A")
      doc_b = make_kb_document(account, display_name: "Manual B (no data)")
      write_overview_cache(account, doc_a, sections: [ { label: "ELECTRICAL", first_page: 1, last_page: 5, chunk_count: 2 } ])
      # doc_b: no cache entry, and DocumentOverviewBuilder finds no manifest/BulkUploadAsset — stays nil.

      result = DocumentOverviewResponder.new(account: account, kb_documents: [ doc_a, doc_b ]).execute

      assert_includes result[:answer], "Documento: Manual A"
      assert_not_includes result[:answer], "Manual B (no data)"
      assert_equal 1, result[:doc_refs].size
    end

    test "execute returns nil when none of the pinned documents have an overview" do
      account = make_account
      doc = make_kb_document(account, display_name: "Manual A")

      assert_nil DocumentOverviewResponder.new(account: account, kb_documents: [ doc ]).execute
    end

    test "execute is cross-account isolated (cache keyed by account_id)" do
      account = make_account
      other_account = make_account
      doc = make_kb_document(account, display_name: "Manual A")
      write_overview_cache(other_account, doc, sections: [ { label: "SEGURIDADES", first_page: 1, last_page: 3, chunk_count: 1 } ])

      assert_nil DocumentOverviewResponder.new(account: account, kb_documents: [ doc ]).execute
    end

    test "execute resolves N documents' overviews with a single cache read_multi" do
      account = make_account
      doc_a = make_kb_document(account, display_name: "Manual A")
      doc_b = make_kb_document(account, display_name: "Manual B")
      write_overview_cache(account, doc_a, sections: [ { label: "ELECTRICAL", first_page: 1, last_page: 5, chunk_count: 1 } ])
      write_overview_cache(account, doc_b, sections: [ { label: "CONTROLES", first_page: 1, last_page: 8, chunk_count: 1 } ])

      calls = 0
      original = Rails.cache.method(:read_multi)
      Rails.cache.define_singleton_method(:read_multi) do |*keys|
        calls += 1
        original.call(*keys)
      end

      DocumentOverviewResponder.new(account: account, kb_documents: [ doc_a, doc_b ]).execute

      assert_equal 1, calls
    end

    test "quick_replies total stays within MAX_QUICK_REPLIES across multiple documents with abundant sections" do
      account = make_account
      doc_a = make_kb_document(account, display_name: "Manual A")
      doc_b = make_kb_document(account, display_name: "Manual B")
      many_sections = ->(prefix) { 5.times.map { |i| { label: "#{prefix}#{i}", first_page: i + 1, last_page: i + 1, chunk_count: 1 } } }
      write_overview_cache(account, doc_a, sections: many_sections.call("A-SECTION-"))
      write_overview_cache(account, doc_b, sections: many_sections.call("B-SECTION-"))

      result = DocumentOverviewResponder.new(account: account, kb_documents: [ doc_a, doc_b ]).execute

      assert result[:quick_replies].size <= DocumentOverviewResponder::MAX_QUICK_REPLIES
    end

    test "quick_replies prefix the query with the document name when multiple documents are rendered" do
      account = make_account
      doc_a = make_kb_document(account, display_name: "Manual A")
      doc_b = make_kb_document(account, display_name: "Manual B")
      write_overview_cache(account, doc_a, sections: [ { label: "SEGURIDADES", first_page: 1, last_page: 3, chunk_count: 1 } ])
      write_overview_cache(account, doc_b, sections: [ { label: "SEGURIDADES", first_page: 1, last_page: 3, chunk_count: 1 } ])

      result = DocumentOverviewResponder.new(account: account, kb_documents: [ doc_a, doc_b ]).execute
      queries = result[:quick_replies].pluck(:query)

      assert_includes queries, "Manual A — SEGURIDADES — #{I18n.t('rag.document_overview.section_query_suffix')}"
      assert_includes queries, "Manual B — SEGURIDADES — #{I18n.t('rag.document_overview.section_query_suffix')}"
      assert_equal 2, queries.uniq.size, "each quick reply query must disambiguate which document it targets"
    end

    test "quick_replies do not prefix the document name with a single rendered document" do
      account = make_account
      doc = make_kb_document(account, display_name: "Manual A")
      write_overview_cache(account, doc, sections: [ { label: "SEGURIDADES", first_page: 1, last_page: 3, chunk_count: 1 } ])

      result = DocumentOverviewResponder.new(account: account, kb_documents: [ doc ]).execute

      assert_equal "SEGURIDADES — #{I18n.t('rag.document_overview.section_query_suffix')}", result[:quick_replies].first[:query]
    end
  end
end
