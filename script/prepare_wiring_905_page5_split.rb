# frozen_string_literal: true

# Effects: writes a local candidate under tmp/field_companion/oversized_chunk_review/candidate/.
# Does not upload, delete, or start an ingestion job.
#
# Run: bin/rails runner script/prepare_wiring_905_page5_split.rb

require "fileutils"
require "json"

source = Rails.root.join("test/fixtures/files/wiring_905/chunk_p5_1.txt")
sidecar = Rails.root.join("test/fixtures/files/wiring_905/chunk_p5_1.txt.metadata.json")
destination = Rails.root.join("tmp/field_companion/oversized_chunk_review/candidate")
FileUtils.mkdir_p(destination)

parts = Wiring905Page5ChunkSplit.call(body: source.binread, sidecar: sidecar.binread)
parts.each do |part|
  File.binwrite(destination.join(part["filename"]), part["body"])
  File.binwrite(destination.join("#{part["filename"]}.metadata.json"), part["sidecar"])
end

manifest = parts.map do |part|
  part.except("body", "sidecar").merge(
    "sha256" => Digest::SHA256.hexdigest(part["body"]),
    "sidecar_sha256" => Digest::SHA256.hexdigest(part["sidecar"])
  )
end
File.write(destination.join("manifest.json"), JSON.pretty_generate(manifest))
puts JSON.generate(manifest)
