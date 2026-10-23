# frozen_string_literal: true

require "digest"

module Rag
  # Definition catalog for one companion turn, read from the chunk directory
  # of each document already retrieved. It lists and reads that directory
  # once, keeps the pages in Rails.cache, and never writes, embeds, or calls
  # Retrieve. A process that set CompanionDefinitionCatalog.current keeps it.
  class CompanionDefinitionSource
    MAX_DOCUMENTS = 3
    MAX_DOCUMENT_CHUNKS = 200
    CACHE_VERSION = "v1"
    CACHE_TTL = 7.days
    CHUNK_FILE = /chunk_p(?<page>\d+)_\d+\.txt\z/
    S3_URI = %r{\As3://(?<bucket>[^/]+)/(?<key>.+)\z}

    class << self
      def invalidate!(prefix)
        return false if prefix.blank?

        Rails.cache.delete(cache_key(prefix))
      end

      def cache_key(prefix)
        "companion_definition_pages/#{CACHE_VERSION}/#{Digest::SHA256.hexdigest(prefix.to_s)}"
      end
    end

    # @param store_for [#call] bucket name -> object with list_keys(prefix:) and download(key)
    def initialize(store_for: nil)
      @store_for = store_for || ->(bucket) { S3DocumentsService.new(bucket_name: bucket) }
      @stores = {}
    end

    def catalog_for(chunks)
      current = CompanionDefinitionCatalog.current
      return current if current

      pages = documents(chunks).flat_map { |document| pages_for(document) }
      pages.empty? ? nil : CompanionDefinitionCatalog.from_pages(pages)
    end

    private

    def documents(chunks)
      found = {}
      Array(chunks).each do |chunk|
        next if DocumentIdentityScope.reference_only_chunk?(chunk)

        location = chunk[:location_uri].to_s.match(S3_URI)
        next unless location

        metadata = chunk[:metadata].to_h.stringify_keys
        key = metadata["original_source_uri"].presence || metadata["document_id"].presence
        prefix = location[:key].rpartition("/").first
        next if key.blank? || prefix.blank? || found.key?(prefix)

        found[prefix] = { bucket: location[:bucket], prefix: prefix, key: key, metadata: metadata }
        break if found.size >= MAX_DOCUMENTS
      end
      found.values
    end

    def pages_for(document)
      cached = Rails.cache.read(self.class.cache_key(document[:prefix]))
      rows = cached.is_a?(Array) ? cached : read_directory(document)
      rows.map do |row|
        row.merge(
          "document_key" => document[:key],
          "name" => document[:metadata]["canonical_name"].presence || document[:metadata]["original_filename"].to_s
        )
      end
    end

    def read_directory(document)
      store = @stores[document[:bucket]] ||= @store_for.call(document[:bucket])
      keys = Array(store.list_keys(prefix: "#{document[:prefix]}/")).select { |key| key.match?(CHUNK_FILE) }.sort
      rows = keys.first(MAX_DOCUMENT_CHUNKS).filter_map do |key|
        body = store.download(key)
        next if body.blank?

        text = DocumentIdentityScope.omit_terminal_evidence_records(body.dup.force_encoding(Encoding::UTF_8).scrub)
        {
          "page" => key.match(CHUNK_FILE)[:page].to_i,
          "filename" => key.rpartition("/").last,
          "provenance" => "chunk #{key}",
          "text" => text
        }
      end
      Rails.cache.write(self.class.cache_key(document[:prefix]), rows, expires_in: CACHE_TTL) if rows.any?
      rows
    end
  end
end
