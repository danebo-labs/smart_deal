# frozen_string_literal: true

require "test_helper"

class ChunkAliasExtractorTest < ActiveSupport::TestCase
  SAMPLE_CHUNK = <<~CHUNK
    **Document:** Junction Box Car Top | **File:** Junction Box Car Top.pdf
    | Field | Value |
    |---|---|
    | **ORIGINAL_FILE_NAME** | Junction Box Car Top.pdf |
    **DOCUMENT_ALIASES:**
    - Junction Box Car Top
    - junction, box, car top
    - DRG 6061-05-014
    - DRG 05-015
    - WT 3-6-05
    - Car Top Junction Box
  CHUNK

  test "parse_canonical extracts document name from header" do
    extractor = ChunkAliasExtractor.allocate
    canonical = extractor.send(:parse_canonical, SAMPLE_CHUNK)
    assert_equal "Junction Box Car Top", canonical
  end

  test "parse_canonical strips trailing .pdf" do
    content = '**Document:** Motor Controller v2.pdf | **File:** Motor Controller v2.pdf'
    extractor = ChunkAliasExtractor.allocate
    assert_equal "Motor Controller v2", extractor.send(:parse_canonical, content)
  end

  test "parse_canonical returns nil when no header" do
    extractor = ChunkAliasExtractor.allocate
    assert_nil extractor.send(:parse_canonical, "no header here")
  end

  test "parse_aliases extracts bullet list items" do
    extractor = ChunkAliasExtractor.allocate
    aliases = extractor.send(:parse_aliases, SAMPLE_CHUNK)
    assert_includes aliases, "Junction Box Car Top"
    assert_includes aliases, "junction, box, car top"
    assert_includes aliases, "DRG 6061-05-014"
    assert_includes aliases, "Car Top Junction Box"
    assert_equal 6, aliases.size
  end

  test "parse_aliases returns empty array when no aliases block" do
    extractor = ChunkAliasExtractor.allocate
    assert_equal [], extractor.send(:parse_aliases, "no aliases here")
  end

  test "build_s3_uri constructs correct path from wa_filename" do
    extractor = ChunkAliasExtractor.allocate
    uri = extractor.send(:build_s3_uri, "wa_20260326_012702_0.jpeg")
    assert_equal "s3://multimodal-source-destination/uploads/2026-03-26/wa_20260326_012702_0.jpeg", uri
  end
end
