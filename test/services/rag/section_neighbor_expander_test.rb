# frozen_string_literal: true

require "test_helper"

# docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md §7 etapa 5: mechanism
# precedence (section_identity over the interim adjacent-page signal) and the
# rule that expansion never crosses into a neighbor's own, different section.
class Rag::SectionNeighborExpanderTest < ActiveSupport::TestCase
  class FakeS3
    attr_reader :bucket_name

    def initialize(objects)
      @bucket_name = "test-bucket"
      @objects = objects
    end

    def list_keys(prefix:)
      @objects.keys.select { |key| key.start_with?(prefix) }
    end

    # Mirrors the real S3DocumentsService#download contract, which ends in
    # `.force_encoding(Encoding::BINARY)` because it also serves PDFs and images.
    # Returning UTF-8 literals here is what let the ASCII-8BIT crash reach
    # production undetected.
    def download(key)
      @objects[key]&.dup&.force_encoding(Encoding::BINARY)
    end
  end

  def divider(content:, metadata: {}, page: 3)
    {
      content: content,
      metadata: metadata.merge("page_number" => page),
      location_uri: "s3://test-bucket/bulk_chunks/1/doc/chunk_0.txt",
      chunk_sha256: "divider-sha",
      rank: 1
    }
  end

  test "adjacent page mechanism authorizes a plain neighbor with no section_identity" do
    s3 = FakeS3.new(
      "bulk_chunks/1/doc/chunk_1.txt" => "12 | STOP Y SEGURIDADES HUECO",
      "bulk_chunks/1/doc/chunk_1.txt.metadata.json" => JSON.generate(
        "metadataAttributes" => { "page_number" => 4 }
      )
    )
    expander = Rag::SectionNeighborExpander.new(s3_service: s3)

    result = expander.neighbor_chunk(divider_chunk: divider(content: "## ENIER MXL1\n"), target_page: 4)

    assert result
    assert_equal :adjacent_page_interim, result[:mechanism]
    assert_equal "12 | STOP Y SEGURIDADES HUECO", result[:chunk][:content]
  end

  test "section_identity mechanism wins when divider and neighbor agree" do
    s3 = FakeS3.new(
      "bulk_chunks/1/doc/chunk_1.txt" => "SPM | SERIE PUERTAS CABINA - EXTERIORES",
      "bulk_chunks/1/doc/chunk_1.txt.metadata.json" => JSON.generate(
        "metadataAttributes" => { "page_number" => 10, "section_identity" => "CARLOS SILVA" }
      )
    )
    expander = Rag::SectionNeighborExpander.new(s3_service: s3)
    divider_chunk = divider(content: "## HIDRA\n", metadata: { "section_identity" => "CARLOS SILVA" })

    result = expander.neighbor_chunk(divider_chunk: divider_chunk, target_page: 10)

    assert_equal :section_identity, result[:mechanism]
  end

  test "never falls back to the interim mechanism when section_identity disagrees" do
    s3 = FakeS3.new(
      "bulk_chunks/1/doc/chunk_1.txt" => "X1 | SERIE TEST",
      "bulk_chunks/1/doc/chunk_1.txt.metadata.json" => JSON.generate(
        "metadataAttributes" => { "page_number" => 79, "section_identity" => "SISTEL" }
      )
    )
    expander = Rag::SectionNeighborExpander.new(s3_service: s3)
    divider_chunk = divider(content: "## EM66\n", metadata: { "section_identity" => "CARLOS SILVA" })

    assert_nil expander.neighbor_chunk(divider_chunk: divider_chunk, target_page: 79)
  end

  test "never crosses into a neighbor that declares its own, different section heading" do
    s3 = FakeS3.new(
      "bulk_chunks/1/doc/chunk_1.txt" => "## OTRA SECCION\nContenido no relacionado.",
      "bulk_chunks/1/doc/chunk_1.txt.metadata.json" => JSON.generate(
        "metadataAttributes" => { "page_number" => 4 }
      )
    )
    expander = Rag::SectionNeighborExpander.new(s3_service: s3)
    divider_chunk = divider(content: "## ENIER MXL1\n")

    assert_nil expander.neighbor_chunk(divider_chunk: divider_chunk, target_page: 4)
  end

  # Regression: S3DocumentsService#download returns ASCII-8BIT, and the selector
  # feeds this body straight into Rag::QueryEntities, whose strip_diacritics
  # calls unicode_normalize — which raises Encoding::CompatibilityError on
  # ASCII-8BIT. Every successful expansion aborted on the first accented
  # character, and no test caught it because both doubles returned UTF-8.
  test "the neighbor body is usable UTF-8 even though S3 hands back binary" do
    accented = "12 | SERIE STOP Y SEGURIDADES HUECO — fotocélula, presostato\n"
    s3 = FakeS3.new(
      "bulk_chunks/1/doc/chunk_1.txt" => accented,
      "bulk_chunks/1/doc/chunk_1.txt.metadata.json" => JSON.generate(
        "metadataAttributes" => { "page_number" => 4, "aliases" => [ "MIGUEL ANGEL NUÑEZ LUZ" ] }
      )
    )
    expander = Rag::SectionNeighborExpander.new(s3_service: s3)

    result = expander.neighbor_chunk(divider_chunk: divider(content: "ENIER\n"), target_page: 4)

    assert result, "expected the accented neighbor to resolve"
    assert_equal Encoding::UTF_8, result[:chunk][:content].encoding
    assert_includes result[:chunk][:content], "fotocélula"
    # The real consumer must not raise on it.
    assert_nothing_raised { Rag::QueryEntities.identifiers(result[:chunk][:content]) }
  end

  test "returns nil when the target page is not present in the index" do
    s3 = FakeS3.new(
      "bulk_chunks/1/doc/chunk_1.txt.metadata.json" => JSON.generate(
        "metadataAttributes" => { "page_number" => 4 }
      )
    )
    expander = Rag::SectionNeighborExpander.new(s3_service: s3)

    assert_nil expander.neighbor_chunk(divider_chunk: divider(content: "## ENIER MXL1\n"), target_page: 99)
  end
end
