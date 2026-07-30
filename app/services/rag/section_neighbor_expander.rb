# frozen_string_literal: true

require "digest"
require "json"

module Rag
  # Divider-page repair for Rag::EvidenceCandidateSelector etapa 5
  # (docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md §7). Reads the S3
  # sidecar the same way Rag::DocumentOverviewBuilder does (GET sidecars, no
  # write, no second Retrieve call, no new embedding) — it does not reuse that
  # class directly because its cached manifest only holds section label/page
  # ranges, not a page -> chunk-key index, and this document's chunks are keyed
  # `chunk_{idx}.txt` (web_v1 ingestion), which does not encode the page number.
  # Resolving a neighbor therefore requires reading the sidecars once per
  # divider to build that index; never writes anything back to S3.
  class SectionNeighborExpander
    MAX_INDEX_CHUNKS = 500

    MECHANISM_SECTION_IDENTITY = :section_identity
    MECHANISM_ADJACENT_PAGE    = :adjacent_page_interim

    HEADING_LINE = /\A##\s+(.+)\z/

    def initialize(s3_service: nil)
      @s3 = s3_service || S3DocumentsService.new
      @index_cache = {}
    end

    # @param divider_chunk [Hash] the chunk that passed identity but failed etapa 3
    # @param target_page [Integer]
    # @return [{chunk:: Hash, mechanism: Symbol}, nil]
    def neighbor_chunk(divider_chunk:, target_page:)
      prefix = prefix_from(divider_chunk)
      return nil if prefix.blank?

      entry = page_index(prefix)[target_page]
      return nil unless entry

      body = text_body(@s3.download(entry[:key]))
      return nil if body.blank?

      mechanism = authorize(divider_chunk, entry, body)
      return nil unless mechanism

      {
        chunk: {
          content: body,
          metadata: entry[:metadata],
          location_uri: "s3://#{@s3.bucket_name}/#{entry[:key]}",
          chunk_sha256: Digest::SHA256.hexdigest(body),
          rank: divider_chunk[:rank]
        },
        mechanism: mechanism
      }
    end

    private

    # S3DocumentsService#download forces Encoding::BINARY because it also serves
    # PDFs and images. A chunk body and a sidecar are text: left as ASCII-8BIT,
    # the first accented character makes Rag::QueryEntities.strip_diacritics
    # raise Encoding::CompatibilityError ("Unicode Normalization not appropriate
    # for ASCII-8BIT") as soon as Rag::EvidenceCandidateSelector re-evaluates
    # this neighbor — so every successful expansion aborted. `dup` because a
    # test double may hand back a frozen literal; `scrub` so an invalid byte
    # degrades to U+FFFD instead of raising later.
    def text_body(body)
      return body if body.nil?

      body.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def prefix_from(chunk)
      uri = chunk[:location_uri].to_s
      return nil if uri.blank?

      path = uri.sub(%r{\As3://[^/]+/}, "")
      path.rpartition("/").first.presence
    end

    # Page -> {key:, metadata:} index over the chunk directory's sidecars, built
    # once per prefix per expander instance (an expander is scoped to a single
    # selector run). Bounded like Rag::DocumentOverviewBuilder::MAX_COLD_BUILD_CHUNKS
    # to cap the worst case of a directory with many small chunks.
    def page_index(prefix)
      @index_cache[prefix] ||= begin
        keys = @s3.list_keys(prefix: "#{prefix}/")
          .select { |key| key.end_with?(".metadata.json") }
          .first(MAX_INDEX_CHUNKS)

        keys.each_with_object({}) do |key, index|
          raw = text_body(@s3.download(key))
          next if raw.blank?

          attributes = JSON.parse(raw)["metadataAttributes"] || {}
          page = Integer(attributes["page_number"], exception: false)
          next unless page

          index[page] = { key: key.delete_suffix(".metadata.json"), metadata: attributes }
        rescue JSON::ParserError
          next
        end
      end
    end

    # Precedence from §7 etapa 5: mechanism 1 (section_identity equal between
    # divider and neighbor) wins once it exists (post Fase 2 backfill + KB sync);
    # mechanism 2 (adjacent page, same document, neighbor doesn't declare its own
    # distinct section) is the only one reachable today for SEGURIDADES (v5).
    def authorize(divider_chunk, entry, neighbor_body)
      divider_metadata = stringified_metadata(divider_chunk)
      divider_identity = divider_metadata["section_identity"].presence
      neighbor_identity = entry[:metadata]["section_identity"].presence

      return MECHANISM_SECTION_IDENTITY if divider_identity.present? && divider_identity == neighbor_identity
      return nil if divider_identity.present? # v7 documents: no silent fallback to the interim mechanism

      neighbor_heading = heading_label(neighbor_body)
      return MECHANISM_ADJACENT_PAGE if neighbor_heading.blank?

      divider_heading = heading_label(divider_chunk[:content].to_s)
      return MECHANISM_ADJACENT_PAGE if divider_heading.present? && neighbor_heading.casecmp?(divider_heading)

      nil # neighbor declares its own, different section — never cross it
    end

    def heading_label(body)
      line = body.to_s.lines.map(&:strip).find { |candidate| candidate.match?(HEADING_LINE) }
      return nil unless line

      line.sub(HEADING_LINE, '\1').strip.presence
    end

    def stringified_metadata(chunk)
      (chunk[:metadata] || chunk["metadata"] || {}).to_h.stringify_keys
    end
  end
end
