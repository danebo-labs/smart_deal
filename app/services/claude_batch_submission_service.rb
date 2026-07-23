# frozen_string_literal: true

# Submits lazy request items in bounded Anthropic Message Batch groups.
# Grouping uses raw binary bytes because base64/JSON payloads are not built yet.
class ClaudeBatchSubmissionService
  BASE64_JSON_MULTIPLIER = 1.37
  DEFAULT_TARGET_MB      = 50
  DEFAULT_MAX_RAW_MB     = 150
  DEFAULT_MAX_REQUESTS   = 100

  attr_reader :max_raw_bytes

  class PayloadTooLargeError < StandardError
    attr_reader :custom_id, :raw_bytes, :estimated_payload_bytes

    def initialize(custom_id:, raw_bytes:, max_raw_bytes:)
      @custom_id              = custom_id
      @raw_bytes              = raw_bytes
      @estimated_payload_bytes = (raw_bytes * BASE64_JSON_MULTIPLIER).ceil
      super(
        "Request #{custom_id} exceeds ingestion payload guardrail " \
        "(raw=#{raw_bytes} bytes, max_raw=#{max_raw_bytes} bytes)"
      )
    end
  end

  def initialize(batch_client:, target_raw_bytes: nil, max_raw_bytes: nil, max_requests: nil)
    @batch_client     = batch_client
    @max_raw_bytes    = max_raw_bytes || megabytes_from_env("INGESTION_MAX_BATCH_PAYLOAD_MB", DEFAULT_MAX_RAW_MB)
    configured_target = target_raw_bytes || megabytes_from_env("INGESTION_BATCH_TARGET_MB", DEFAULT_TARGET_MB)
    @target_raw_bytes = [ configured_target, @max_raw_bytes ].min
    @max_requests     = max_requests || positive_integer_env("INGESTION_BATCH_MAX_REQUESTS", DEFAULT_MAX_REQUESTS)
  end

  # @return [Array<String>] every submitted Anthropic batch id, in group order
  def submit!(items)
    groups = slice(items)
    batch_ids = groups.map.with_index do |group, index|
      requests = group.map(&:build)
      batch = @batch_client.submit_batch(requests: requests)
      raise "Anthropic batch group #{index + 1} returned no id" if batch.id.blank?

      Rails.logger.info(
        "ClaudeBatchSubmissionService: submitted group=#{index + 1}/#{groups.size} " \
        "requests=#{group.size} raw_bytes=#{group.sum(&:byte_size)} batch_id=#{batch.id}"
      )
      batch.id
    ensure
      requests = nil
    end

    batch_ids
  ensure
    Array(items).each(&:cleanup)
  end

  def slice(items)
    groups        = []
    current       = []
    current_bytes = 0

    Array(items).each do |item|
      validate_item!(item)

      if current.any? &&
          (current.size >= @max_requests || current_bytes + item.byte_size > @target_raw_bytes)
        groups << current
        current       = []
        current_bytes = 0
      end

      current << item
      current_bytes += item.byte_size
    end

    groups << current if current.any?
    groups
  rescue StandardError
    Array(items).each(&:cleanup)
    raise
  end

  def oversized?(item)
    item.byte_size > max_raw_bytes
  end

  private

  def validate_item!(item)
    return if item.byte_size <= @max_raw_bytes

    raise PayloadTooLargeError.new(
      custom_id: item.custom_id,
      raw_bytes: item.byte_size,
      max_raw_bytes: @max_raw_bytes
    )
  end

  def megabytes_from_env(name, default)
    value = ENV.fetch(name, default).to_f
    value = default unless value.positive?
    (value * 1024 * 1024).to_i
  end

  def positive_integer_env(name, default)
    value = ENV.fetch(name, default).to_i
    value.positive? ? value : default
  end
end
