# frozen_string_literal: true

require "test_helper"

module Rag
  class DocumentOverviewCacheTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rails.cache = @previous_cache
    end

    SAMPLE_VALUE = {
      sections: [ { label: "Sección 1", first_page: 1, last_page: 5, chunk_count: 3 } ],
      chunk_count: 3,
      source: "manifest"
    }.freeze

    test "round-trips write and read" do
      DocumentOverviewCache.write(account_id: 1, kb_document_id: 42, value: SAMPLE_VALUE)

      result = DocumentOverviewCache.read(account_id: 1, kb_document_id: 42)

      assert_equal SAMPLE_VALUE[:sections], result[:sections]
      assert_equal SAMPLE_VALUE[:chunk_count], result[:chunk_count]
      assert_equal SAMPLE_VALUE[:source], result[:source]
      assert result[:generated_at].present?
    end

    test "read returns nil and deletes the key when payload is incomplete" do
      Rails.cache.write(DocumentOverviewCache.key(account_id: 1, kb_document_id: 42), { sections: [] })

      assert_nil DocumentOverviewCache.read(account_id: 1, kb_document_id: 42)
      assert_nil Rails.cache.read(DocumentOverviewCache.key(account_id: 1, kb_document_id: 42))
    end

    test "read returns nil when nothing cached" do
      assert_nil DocumentOverviewCache.read(account_id: 1, kb_document_id: 999)
    end

    test "isolates by account_id" do
      DocumentOverviewCache.write(account_id: 1, kb_document_id: 42, value: SAMPLE_VALUE)

      assert_nil DocumentOverviewCache.read(account_id: 2, kb_document_id: 42)
    end

    test "isolates by kb_document_id" do
      DocumentOverviewCache.write(account_id: 1, kb_document_id: 42, value: SAMPLE_VALUE)

      assert_nil DocumentOverviewCache.read(account_id: 1, kb_document_id: 43)
    end

    test "invalidate deletes the cached value" do
      DocumentOverviewCache.write(account_id: 1, kb_document_id: 42, value: SAMPLE_VALUE)
      DocumentOverviewCache.invalidate(account_id: 1, kb_document_id: 42)

      assert_nil DocumentOverviewCache.read(account_id: 1, kb_document_id: 42)
    end

    # ─── read_multi (V4) ────────────────────────────────────────────────────

    test "read_multi returns cached values for all hits in a single lookup" do
      DocumentOverviewCache.write(account_id: 1, kb_document_id: 42, value: SAMPLE_VALUE)
      DocumentOverviewCache.write(account_id: 1, kb_document_id: 43, value: SAMPLE_VALUE)

      result = DocumentOverviewCache.read_multi(account_id: 1, kb_document_ids: [ 42, 43 ])

      assert_equal [ 42, 43 ].sort, result.keys.sort
      assert_equal SAMPLE_VALUE[:source], result[42][:source]
    end

    test "read_multi omits misses instead of raising" do
      DocumentOverviewCache.write(account_id: 1, kb_document_id: 42, value: SAMPLE_VALUE)

      result = DocumentOverviewCache.read_multi(account_id: 1, kb_document_ids: [ 42, 999 ])

      assert_equal [ 42 ], result.keys
    end

    test "read_multi discards and invalidates schema-drifted entries" do
      Rails.cache.write(DocumentOverviewCache.key(account_id: 1, kb_document_id: 42), { sections: [] })

      result = DocumentOverviewCache.read_multi(account_id: 1, kb_document_ids: [ 42 ])

      assert_empty result
      assert_nil Rails.cache.read(DocumentOverviewCache.key(account_id: 1, kb_document_id: 42))
    end

    test "read_multi returns an empty hash for an empty id list" do
      assert_equal({}, DocumentOverviewCache.read_multi(account_id: 1, kb_document_ids: []))
    end

    test "read_multi issues a single cache read for N documents" do
      DocumentOverviewCache.write(account_id: 1, kb_document_id: 42, value: SAMPLE_VALUE)
      DocumentOverviewCache.write(account_id: 1, kb_document_id: 43, value: SAMPLE_VALUE)

      calls = 0
      original = Rails.cache.method(:read_multi)
      Rails.cache.define_singleton_method(:read_multi) do |*keys|
        calls += 1
        original.call(*keys)
      end

      DocumentOverviewCache.read_multi(account_id: 1, kb_document_ids: [ 42, 43 ])

      assert_equal 1, calls
    end
  end
end
