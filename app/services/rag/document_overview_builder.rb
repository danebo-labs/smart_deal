# frozen_string_literal: true

module Rag
  # Deterministic table-of-contents builder for a pinned document. Zero Bedrock
  # calls, always. Resolution order (stop at first hit):
  #   1. Solid Cache (Rag::DocumentOverviewCache) — zero I/O.
  #   2. S3 manifest under document_manifests/ — 1 GET.
  #   3. Cold build from chunk sidecars — only when allow_cold_build is true.
  #      Bounded by MAX_COLD_BUILD_CHUNKS; self-heals by writing the manifest +
  #      cache so every subsequent call costs 1 GET or 0.
  #
  # document_manifests/ is deliberately OUTSIDE bulk_chunks/, the only prefix
  # indexed by the Bedrock data source. Never move this manifest under
  # bulk_chunks/ — it would be ingested as a phantom KB document.
  class DocumentOverviewBuilder
    MANIFEST_PREFIX  = "document_manifests"
    MANIFEST_VERSION = "toc_v1"
    # Bounds the worst case of a cold build (1 S3 GET per sidecar).
    MAX_COLD_BUILD_CHUNKS = 400

    # @return [Hash, nil] { sections:, chunk_count:, source: } or nil when the
    #   document has no usable section structure / data is unavailable.
    def self.call(account:, kb_document:, allow_cold_build: false, s3_service: nil)
      new(account: account, kb_document: kb_document, s3_service: s3_service)
        .call(allow_cold_build: allow_cold_build)
    end

    def initialize(account:, kb_document:, s3_service: nil)
      @account     = account
      @kb_document = kb_document
      @s3          = s3_service || S3DocumentsService.new
    end

    def call(allow_cold_build: false)
      cached = Rag::DocumentOverviewCache.read(account_id: @account.id, kb_document_id: @kb_document.id)
      return cached if cached

      manifest = read_manifest
      if manifest
        Rag::DocumentOverviewCache.write(account_id: @account.id, kb_document_id: @kb_document.id, value: manifest)
        return manifest
      end

      return nil unless allow_cold_build

      build_cold
    end

    private

    def read_manifest
      raw = @s3.download(manifest_key)
      return nil if raw.blank?

      parsed = JSON.parse(raw).deep_symbolize_keys
      return nil if parsed[:sections].blank?

      { sections: parsed[:sections], chunk_count: parsed[:chunk_count], source: "manifest" }
    rescue JSON::ParserError => e
      Rails.logger.warn("Rag::DocumentOverviewBuilder: corrupt manifest #{manifest_key} — #{e.message}")
      nil
    end

    def build_cold
      prefix, count = BulkUploadAsset.where(kb_document_id: @kb_document.id).pick(:chunks_s3_prefix, :chunks_count)
      if prefix.blank?
        prefix, count = WebManualBatch.where(kb_document_id: @kb_document.id).pick(:chunks_s3_prefix, :chunks_count)
      end
      return nil if prefix.blank?
      return nil if count.to_i > MAX_COLD_BUILD_CHUNKS

      keys = @s3.list_keys(prefix: "#{prefix}/").select { |key| key.end_with?(".metadata.json") }
      return nil if keys.empty?

      sections = sections_from_sidecars(keys)
      return nil if sections.empty?

      payload = { sections: sections, chunk_count: keys.size, source: "cold_build" }
      persist_manifest(payload)
      payload
    end

    def sections_from_sidecars(keys)
      entries = keys.filter_map { |key| parse_sidecar(key) }
      return [] if entries.none? { |entry| entry[:section_identity].present? }

      entries
        .select { |entry| entry[:section_identity].present? }
        .group_by { |entry| entry[:section_identity] }
        .map do |section_identity, group|
          pages = group.filter_map { |entry| entry[:page_number] }.sort
          {
            label: section_identity,
            first_page: pages.first,
            last_page: pages.last,
            chunk_count: group.size
          }
        end
        .sort_by { |section| section[:first_page] || Float::INFINITY }
    end

    def parse_sidecar(key)
      raw = @s3.download(key)
      return nil if raw.blank?

      attributes = JSON.parse(raw)["metadataAttributes"] || {}
      {
        section_identity: attributes["section_identity"].presence,
        page_number: Integer(attributes["page_number"], exception: false)
      }
    rescue JSON::ParserError => e
      Rails.logger.warn("Rag::DocumentOverviewBuilder: corrupt sidecar #{key} — #{e.message}")
      nil
    end

    def persist_manifest(payload)
      @s3.upload_binary(manifest_key, JSON.generate(payload), "application/json")
      Rag::DocumentOverviewCache.write(account_id: @account.id, kb_document_id: @kb_document.id, value: payload)
    end

    def manifest_key
      "#{MANIFEST_PREFIX}/#{@account.id}/#{@kb_document.document_uid}/#{MANIFEST_VERSION}.json"
    end
  end
end
