# frozen_string_literal: true

require "test_helper"

module Rag
  class DocumentOverviewBuilderTest < ActiveSupport::TestCase
    class FakeS3
      attr_reader :list_keys_calls, :download_calls, :uploads

      def initialize(objects: {})
        @objects        = objects
        @list_keys_calls = []
        @download_calls  = []
        @uploads         = {}
      end

      def list_keys(prefix:)
        @list_keys_calls << prefix
        @objects.keys.select { |key| key.start_with?(prefix) }
      end

      def download(key)
        @download_calls << key
        @objects[key]
      end

      def upload_binary(key, data, content_type)
        @uploads[key] = { data: data, content_type: content_type }
        key
      end
    end

    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new

      @account     = Account.create!(display_name: "Overview Builder Co", slug: "overview-builder-#{SecureRandom.hex(4)}")
      @kb_document = KbDocument.create!(account: @account, s3_key: "uploads/manual.pdf", display_name: "Manual")
    end

    teardown do
      Rails.cache = @previous_cache
    end

    def manifest_key
      "document_manifests/#{@account.id}/#{@kb_document.document_uid}/toc_v1.json"
    end

    def build(s3, allow_cold_build: false)
      DocumentOverviewBuilder.call(
        account: @account, kb_document: @kb_document,
        allow_cold_build: allow_cold_build, s3_service: s3
      )
    end

    def web_manual_batch(prefix:, count:)
      WebManualBatch.create!(
        account: @account, kb_document: @kb_document,
        s3_key: "uploads/manual.pdf", filename: "manual.pdf",
        sha256: SecureRandom.hex(32), ingestion_contract_version: "v1",
        chunks_s3_prefix: prefix, chunks_count: count
      )
    end

    test "cache hit returns cached value without touching S3" do
      Rag::DocumentOverviewCache.write(
        account_id: @account.id, kb_document_id: @kb_document.id,
        value: { sections: [ { label: "S1", first_page: 1, last_page: 2, chunk_count: 1 } ],
                 chunk_count: 1, source: "manifest" }
      )
      s3 = FakeS3.new

      result = build(s3, allow_cold_build: true)

      assert_equal "manifest", result[:source]
      assert_empty s3.list_keys_calls
      assert_empty s3.download_calls
    end

    test "manifest hit reads once, writes cache, and never lists sidecars" do
      manifest = { sections: [ { label: "S1", first_page: 1, last_page: 3, chunk_count: 2 } ],
                   chunk_count: 2, source: "cold_build" }
      s3 = FakeS3.new(objects: { manifest_key => JSON.generate(manifest) })

      result = build(s3)

      assert_equal "manifest", result[:source]
      assert_equal 1, result[:sections].size
      assert_empty s3.list_keys_calls
      assert_equal [ manifest_key ], s3.download_calls

      cached = Rag::DocumentOverviewCache.read(account_id: @account.id, kb_document_id: @kb_document.id)
      assert_equal "manifest", cached[:source]
    end

    test "cold build groups sidecars into sections ordered by first page and writes the manifest" do
      prefix = "bulk_chunks/#{@account.id}/#{@kb_document.document_uid}"
      web_manual_batch(prefix: prefix, count: 3)

      sidecar = ->(section, page) { JSON.generate("metadataAttributes" => { "section_identity" => section, "page_number" => page }) }
      objects = {
        "#{prefix}/chunk_0.txt.metadata.json" => sidecar.call("SEGURIDADES", 5),
        "#{prefix}/chunk_1.txt.metadata.json" => sidecar.call("ELECTRICAL", 1),
        "#{prefix}/chunk_2.txt.metadata.json" => sidecar.call("SEGURIDADES", 6),
        "#{prefix}/chunk_0.txt" => "irrelevant body text"
      }
      s3 = FakeS3.new(objects: objects)

      result = build(s3, allow_cold_build: true)

      assert_equal "cold_build", result[:source]
      assert_equal 3, result[:chunk_count]
      assert_equal [ "ELECTRICAL", "SEGURIDADES" ], result[:sections].pluck(:label)

      electrical = result[:sections].find { |s| s[:label] == "ELECTRICAL" }
      assert_equal 1, electrical[:first_page]
      assert_equal 1, electrical[:last_page]
      assert_equal 1, electrical[:chunk_count]

      seguridades = result[:sections].find { |s| s[:label] == "SEGURIDADES" }
      assert_equal 5, seguridades[:first_page]
      assert_equal 6, seguridades[:last_page]
      assert_equal 2, seguridades[:chunk_count]

      assert s3.uploads.key?(manifest_key)
      assert_equal "application/json", s3.uploads[manifest_key][:content_type]
      cached = Rag::DocumentOverviewCache.read(account_id: @account.id, kb_document_id: @kb_document.id)
      assert_equal "cold_build", cached[:source]
    end

    test "returns nil when no sidecar has a section_identity" do
      prefix = "bulk_chunks/#{@account.id}/#{@kb_document.document_uid}"
      web_manual_batch(prefix: prefix, count: 1)
      objects = { "#{prefix}/chunk_0.txt.metadata.json" => JSON.generate("metadataAttributes" => { "page_number" => 1 }) }
      s3 = FakeS3.new(objects: objects)

      assert_nil build(s3, allow_cold_build: true)
      assert_not s3.uploads.key?(manifest_key)
    end

    test "returns nil without listing when chunks_count exceeds the max" do
      prefix = "bulk_chunks/#{@account.id}/#{@kb_document.document_uid}"
      web_manual_batch(prefix: prefix, count: DocumentOverviewBuilder::MAX_COLD_BUILD_CHUNKS + 1)
      s3 = FakeS3.new

      assert_nil build(s3, allow_cold_build: true)
      assert_empty s3.list_keys_calls
    end

    test "returns nil without listing when allow_cold_build is false and nothing is cached" do
      s3 = FakeS3.new

      assert_nil build(s3, allow_cold_build: false)
      assert_empty s3.list_keys_calls
    end
  end
end
