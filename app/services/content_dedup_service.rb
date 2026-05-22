# frozen_string_literal: true

# SHA-256 dedup for web custom chunking path.
# Looks up a completed BulkUploadAsset by the first 32 hex chars of the binary's
# SHA-256 digest (same truncation used by BulkUploadAsset.custom_id_for).
# Hit → return canonical identity so the pipeline can skip re-parsing.
# Miss → caller proceeds with SingleFileChunkingService.
class ContentDedupService
  Result = Struct.new(:hit, :asset, :canonical_name, :aliases, keyword_init: true)

  def self.find_completed(sha256:)
    custom_id = sha256.to_s[0, 32]
    asset     = BulkUploadAsset.complete.find_by(custom_id: custom_id)
    if asset
      Rails.logger.info("ContentDedupService: hit sha256=#{custom_id}")
      Result.new(hit: true, asset: asset, canonical_name: asset.canonical_name, aliases: Array(asset.aliases))
    else
      Result.new(hit: false, asset: nil, canonical_name: nil, aliases: [])
    end
  end
end
