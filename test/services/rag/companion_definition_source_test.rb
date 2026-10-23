# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../support/local_chunk_directory"

class Rag::CompanionDefinitionSourceTest < ActiveSupport::TestCase
  PREFIX = "bulk_chunks/7/doc-bomba"
  URI = "s3://example/bomba.pdf"

  setup do
    @root = Pathname.new(Dir.mktmpdir("companion-definitions"))
    @store = LocalChunkDirectory.new(@root)
    @store.upload_text("#{PREFIX}/chunk_p3_1.txt", "6.1 Averías\nRevisar el regulador de caudal (#9).\n")
    @store.upload_text("#{PREFIX}/chunk_p5_1.txt", "4.2 Regulador (9)\nEl regulador de caudal fija el paso del agua.\n")
    @store.upload_text("#{PREFIX}/chunk_p5_1.txt.metadata.json", "{}")
    Rails.cache.delete(Rag::CompanionDefinitionSource.cache_key(PREFIX))
  end

  teardown do
    FileUtils.remove_entry(@root)
    Rails.cache.delete(Rag::CompanionDefinitionSource.cache_key(PREFIX))
  end

  test "the definition of a mentioned id comes from the same document's chunk directory" do
    source = Rag::CompanionDefinitionSource.new(store_for: counting_store)
    catalog = source.catalog_for([ retrieved ])
    result = Rag::CompanionDefinitionExpander.expand([ retrieved ], catalog: catalog)

    assert_equal [ "#9" ], result.added.pluck("definition_of")
    assert_equal "5", result.chunks.last[:metadata]["page_number"]
    assert_includes result.chunks.last[:content], "El regulador de caudal fija el paso del agua."
    assert_equal [ "example" ], @buckets
    assert_equal 2, @downloads.size
  end

  test "the directory is read once and an invalidation reads it again" do
    with_memory_cache do
      Rag::CompanionDefinitionSource.new(store_for: counting_store).catalog_for([ retrieved ])
      Rag::CompanionDefinitionSource.new(store_for: counting_store).catalog_for([ retrieved ])
      assert_equal 2, @downloads.size

      assert Rag::CompanionDefinitionSource.invalidate!(PREFIX)
      Rag::CompanionDefinitionSource.new(store_for: counting_store).catalog_for([ retrieved ])
      assert_equal 4, @downloads.size
    end
  end

  test "a process catalog wins, and a reference-only or unlocated chunk reads nothing" do
    process = Rag::CompanionDefinitionCatalog.from_pages([])
    source = Rag::CompanionDefinitionSource.new(store_for: counting_store)

    Rag::CompanionDefinitionCatalog.with(process) { assert_same process, source.catalog_for([ retrieved ]) }
    assert_nil source.catalog_for([ retrieved.merge(identity_applicability: "reference_only") ])
    assert_nil source.catalog_for([ retrieved.merge(location_uri: nil) ])
    assert_empty @downloads
  end

  test "a chunk write under bulk_chunks invalidates the cached pages" do
    with_memory_cache do
      Rails.cache.write(Rag::CompanionDefinitionSource.cache_key(PREFIX), [ { "text" => "old" } ])
      service = S3DocumentsService.allocate
      service.send(:invalidate_section_neighbor_cache, "#{PREFIX}/chunk_p5_1.txt")

      assert_nil Rails.cache.read(Rag::CompanionDefinitionSource.cache_key(PREFIX))
    end
  end

  private

  def retrieved
    {
      content: "6.1 Averías\nRevisar el regulador de caudal (#9).",
      location_uri: "s3://example/#{PREFIX}/chunk_p3_1.txt",
      metadata: { "original_source_uri" => URI, "canonical_name" => "Manual bomba P2", "page_number" => "3" },
      identity_applicability: "compatible"
    }
  end

  def counting_store
    @downloads ||= []
    @buckets ||= []
    store = @store
    downloads = @downloads
    buckets = @buckets
    lambda do |bucket|
      buckets << bucket
      wrapper = Object.new
      wrapper.define_singleton_method(:list_keys) { |prefix:| store.list_keys(prefix: prefix) }
      wrapper.define_singleton_method(:download) do |key|
        downloads << key
        store.download(key)
      end
      wrapper
    end
  end

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end
end
