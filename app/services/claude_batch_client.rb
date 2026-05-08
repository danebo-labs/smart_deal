# frozen_string_literal: true

# Thin wrapper over the `anthropic` gem's Message Batches API.
# Inject a fake client via the `client:` param in tests.
class ClaudeBatchClient
  # @param api_key [String, nil] overrides ENV / credentials
  # @param client  [Object, nil] pre-built Anthropic::Client (for tests)
  def initialize(api_key: nil, client: nil)
    @client = client || Anthropic::Client.new(api_key: resolve_api_key(api_key))
  end

  # Submits a batch of message creation requests.
  # @param requests [Array<Hash>] each: { custom_id:, params: { model:, max_tokens:, system:, messages: } }
  # @return [Anthropic::Models::Messages::MessageBatch]
  def submit_batch(requests:)
    @client.messages.batches.create(requests: requests)
  end

  # Returns the current status of a batch.
  # @param batch_id [String]
  # @return [Anthropic::Models::Messages::MessageBatch]
  def retrieve(batch_id:)
    @client.messages.batches.retrieve(batch_id)
  end

  # Streams individual results for a completed batch.
  # Yields Anthropic::Models::Messages::MessageBatchIndividualResponse
  #   (.custom_id, .result.type → "succeeded" | "errored" | "canceled" | "expired")
  #
  # When the Anthropic response content-type doesn't match the SDK's JSONL
  # pattern, the SDK falls back to wrapping the body in a StringIO and
  # JsonLStream#iterator calls StringIO#each, yielding raw line strings instead
  # of coerced model objects. We detect and re-coerce those strings here.
  # @param batch_id [String]
  def results_each(batch_id:, &block)
    @client.messages.batches.results_streaming(batch_id).each do |result|
      if result.is_a?(String)
        stripped = result.strip
        next if stripped.empty?

        parsed = JSON.parse(stripped, symbolize_names: true)
        result = Anthropic::Internal::Type::Converter.coerce(
          Anthropic::Messages::MessageBatchIndividualResponse, parsed
        )
      end

      block.call(result)
    end
  end

  private

  def resolve_api_key(override)
    override.presence ||
      ENV["ANTHROPIC_API_KEY"].presence ||
      Rails.application.credentials.dig(:anthropic, :api_key)
  end
end
