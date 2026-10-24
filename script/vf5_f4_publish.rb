# frozen_string_literal: true

# Effects: may replace only
#   s3://multimodal-source-destination/bulk_chunks/1/be7a39a3490c92c8381cb883402760cb07d1/
# then start one ingestion job on knowledge base Y7RZWMFJSR, data source PJ0N58DMHG.
# A failed write or sync restores that prefix once and starts one resync.
# Does not print credentials.
#
# Run: bin/rails runner script/vf5_f4_publish.rb

ENV["AWS_REGION"] = Vf5F4Publication::REGION
ENV["KNOWLEDGE_BASE_S3_BUCKET"] = Vf5F4Publication::BUCKET
ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = Vf5F4Publication::KNOWLEDGE_BASE_ID
ENV["BEDROCK_DATA_SOURCE_ID"] = Vf5F4Publication::DATA_SOURCE_ID

begin
  warn "aws_caller=#{Vf5F4Publication.use_operator_profile!}"
rescue ArgumentError => error
  warn error.message
  exit 1
end

unless Vf5F4Publication.credentials_present?
  warn "AWS credentials are not configured"
  exit 1
end

report = Vf5F4Publication.call
summary = {
  "evidence_dir" => report["evidence_dir"],
  "aws_caller" => report["aws_caller"],
  "stopped" => report["stopped"],
  "restore_stopped" => report["restore_stopped"],
  "retrieve_stopped" => report["retrieve_stopped"],
  "rehydrate_stopped" => report["rehydrate_stopped"],
  "restored" => report["restored"],
  "rewrite" => report["rewrite"],
  "remote_candidate_match" => report["remote_candidate_match"],
  "remote_only_keys" => report["remote_only_keys"],
  "candidate_only_keys" => report["candidate_only_keys"],
  "hash_mismatch_count" => Array(report["hash_mismatches"]).size,
  "resolved_data_source_id" => report["resolved_data_source_id"],
  "data_source_bucket_arn" => report["data_source_bucket_arn"],
  "data_source_prefixes" => report["data_source_prefixes"],
  "previous_remote_count" => report["previous_remote_count"],
  "target_sha256" => report["target_sha256"],
  "sync" => report["sync"],
  "sync_result" => report["sync_result"],
  "resync" => report["resync"],
  "resync_result" => report["resync_result"],
  "retrieval_adjustment" => report["retrieval_adjustment"],
  "retrieval" => Array(report["retrieval"]).map { |call|
    {
      "number_of_results" => call["number_of_results"],
      "results" => Array(call["results"]).map { |row| row.slice("rank", "score", "uri", "filename", "phrases") }
    }
  },
  "rehydration" => report["rehydration"],
  "cache_invalidated" => report["cache_invalidated"],
  "review_vf5" => report["review_vf5"]
}
puts JSON.generate(summary)
incomplete = report["stopped"] || report["restore_stopped"] || report["retrieve_stopped"] || report["rehydrate_stopped"]
exit(incomplete ? 1 : 0)
