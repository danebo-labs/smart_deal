# frozen_string_literal: true

# Contract-versioned SHA-256 dedup for web custom chunking path.
# Looks up a completed BulkUploadAsset by the versioned custom_id
# (BulkUploadAsset.custom_id_for_sha) AND a matching ingestion_contract_version
# column. An asset parsed under a different — or absent — contract version is a
# MISS, never a hit: its chunks were produced by an older prompt contract and
# must not be reused for a new index.
# Hit → return canonical identity so the pipeline can skip re-parsing.
# Miss → caller proceeds with SingleFileChunkingService.
class ContentDedupService
  Result = Struct.new(:hit, :asset, :canonical_name, :aliases, keyword_init: true)

  def self.find_completed(sha256:, contract_version:)
    custom_id = BulkUploadAsset.custom_id_for_sha(sha256.to_s, contract_version: contract_version)
    asset = BulkUploadAsset.complete.find_by(
      custom_id: custom_id,
      ingestion_contract_version: contract_version
    )
    if asset
      Rails.logger.info(
        "ContentDedupService: hit sha256=#{sha256.to_s[0, 32]} contract=#{contract_version}"
      )
      Result.new(hit: true, asset: asset, canonical_name: asset.canonical_name, aliases: Array(asset.aliases))
    else
      Result.new(hit: false, asset: nil, canonical_name: nil, aliases: [])
    end
  end
end
