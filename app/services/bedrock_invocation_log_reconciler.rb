# frozen_string_literal: true

require "zlib"
require "json"

# Reads Bedrock Model Invocation Logs from S3 and computes the authoritative
# per-UTC-day cost — the ground truth that matches the AWS bill.
#
# Why this exists: BedrockQuery rows on the retrieve_and_generate path are
# `token_source: "estimated"` (no usage block from R&G) and timestamped at async
# job-run time, so they undercount input tokens (~10%+) AND misattribute the UTC
# day. The invocation logs carry exact inputTokenCount / outputTokenCount /
# cacheRead / cacheWrite plus the real invocation `timestamp`.
#
# Log S3 layout (from get-model-invocation-logging-configuration):
#   <prefix>/AWSLogs/<account>/BedrockModelInvocationLogs/<region>/YYYY/MM/DD/HH/*.json.gz
#
# Usage:
#   BedrockInvocationLogReconciler.new.day(Date.new(2026, 6, 18))
#   #=> { date:, rows: [{model_id:, count:, input_tokens:, ...cost:}], total_cost: }
class BedrockInvocationLogReconciler
  include AwsClientInitializer

  DEFAULT_BUCKET = ENV.fetch("BEDROCK_LOG_BUCKET", "multimodal-logs")
  DEFAULT_PREFIX = ENV.fetch("BEDROCK_LOG_PREFIX", "bedrock-invocation-logs")

  def initialize(bucket: DEFAULT_BUCKET, prefix: DEFAULT_PREFIX, account_id: nil, region: nil, s3: nil)
    @bucket     = bucket
    @prefix     = prefix
    @region     = region || ENV.fetch("AWS_REGION", "us-east-1")
    @account_id = account_id || ENV["AWS_ACCOUNT_ID"].presence || resolve_account_id
    @s3         = s3 || Aws::S3::Client.new(build_aws_client_options(region: @region))
  end

  # Authoritative cost breakdown for one UTC calendar day.
  def day(date)
    rows = Hash.new { |h, k| h[k] = { count: 0, input_tokens: 0, output_tokens: 0,
                                      cache_read_tokens: 0, cache_write_tokens: 0 } }

    each_record(date) do |rec|
      next unless rec["timestamp"].to_s.start_with?(date.strftime("%Y-%m-%d"))

      model = short_model_id(rec["modelId"])
      i = rec.dig("input", "inputTokenCount").to_i
      o = rec.dig("output", "outputTokenCount").to_i
      cr = rec.dig("input", "cacheReadInputTokenCount").to_i
      cw = rec.dig("input", "cacheWriteInputTokenCount").to_i

      agg = rows[model]
      agg[:count] += 1
      agg[:input_tokens] += i
      agg[:output_tokens] += o
      agg[:cache_read_tokens] += cr
      agg[:cache_write_tokens] += cw
    end

    breakdown = rows.map do |model, a|
      pricing = BedrockQuery.new(model_id: model).pricing_for(model)
      cost = (a[:input_tokens] / 1000.0 * pricing[:input]) +
             (a[:output_tokens] / 1000.0 * pricing[:output]) +
             (a[:cache_read_tokens] / 1000.0 * (pricing[:cache_read] || pricing[:input] * 0.1)) +
             (a[:cache_write_tokens] / 1000.0 * (pricing[:cache_creation] || pricing[:input] * 1.25))
      a.merge(model_id: model, cost: cost.round(6))
    end.sort_by { |r| -r[:cost] }

    { date: date, rows: breakdown, total_cost: breakdown.sum { |r| r[:cost] }.round(6) }
  end

  private

  # Yields each parsed JSON log record for the given UTC day across all hours.
  def each_record(date)
    day_prefix = "#{@prefix}/AWSLogs/#{@account_id}/BedrockModelInvocationLogs/" \
                 "#{@region}/#{date.strftime('%Y/%m/%d')}/"

    continuation = nil
    loop do
      resp = @s3.list_objects_v2(bucket: @bucket, prefix: day_prefix, continuation_token: continuation)
      resp.contents.each do |obj|
        next unless obj.key.end_with?(".json.gz")

        body = @s3.get_object(bucket: @bucket, key: obj.key).body.read
        Zlib::GzipReader.new(StringIO.new(body)).each_line do |line|
          line = line.strip
          next if line.empty?

          yield JSON.parse(line)
        rescue JSON::ParserError => e
          Rails.logger.warn("[BedrockInvocationLogReconciler] bad line in #{obj.key}: #{e.message}")
        end
      end
      break unless resp.is_truncated

      continuation = resp.next_continuation_token
    end
  end

  def short_model_id(model_id)
    model_id.to_s.split("/").last
  end

  def resolve_account_id
    Aws::STS::Client.new(build_aws_client_options(region: @region))
                    .get_caller_identity.account
  rescue StandardError => e
    Rails.logger.warn("[BedrockInvocationLogReconciler] STS lookup failed: #{e.message}")
    nil
  end
end
