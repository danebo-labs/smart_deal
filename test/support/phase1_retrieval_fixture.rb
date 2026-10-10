# frozen_string_literal: true

require "digest"
require "json"

# Sanitized retrieval rows from run 20261010T153620Z.
# Bodies and the observed row fields live under test/fixtures. The historical
# tmp directory is not read and was not modified.
module Phase1RetrievalFixture
  ROOT = Rails.root.join("test/fixtures/files/field_companion/phase1_20261010T153620Z")

  def self.manifest
    JSON.parse(File.read(ROOT.join("manifest.json")))
  end

  def self.rows
    manifest.fetch("rows")
  end

  # Chunks for a stubbed Retrieve. page_number is the observed "page" under
  # the key the route already reads. rank is the row order. Neither is a
  # sidecar field. canonical_name and original_source_uri are not filled in:
  # the capture rows did not carry them.
  def self.chunks
    rows.each_with_index.map do |row, index|
      observed = row.fetch("observed")
      content = File.binread(ROOT.join(observed.fetch("body_file"))).force_encoding(Encoding::UTF_8)
      digest = Digest::SHA256.hexdigest(content)
      raise "fixture #{observed["body_file"]} hash drifted" unless digest == observed.fetch("body_sha256")

      {
        content: content,
        location_uri: observed.fetch("uri"),
        chunk_sha256: digest,
        rank: index + 1,
        metadata: { "page_number" => observed.fetch("page").to_i }
      }
    end
  end
end
