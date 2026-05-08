# frozen_string_literal: true

require "test_helper"
require "ostruct"

class ClaudeBatchClientTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  BATCH_ID = "msgbatch_test123"

  # ---------------------------------------------------------------------------
  # Fakes
  # ---------------------------------------------------------------------------

  class FakeBatches
    attr_reader :last_create_params, :last_retrieved_id

    def initialize(batch_id:, processing_status: :in_progress, results: [])
      @batch_id          = batch_id
      @processing_status = processing_status
      @results           = results
      @last_create_params  = nil
      @last_retrieved_id   = nil
    end

    def create(params)
      @last_create_params = params
      OpenStruct.new(id: @batch_id, processing_status: @processing_status)
    end

    def retrieve(batch_id)
      @last_retrieved_id = batch_id
      OpenStruct.new(id: batch_id, processing_status: @processing_status)
    end

    def results_streaming(batch_id) # rubocop:disable Lint/UnusedMethodArgument
      @results.each
    end
  end

  class FakeMessages
    attr_reader :batches

    def initialize(batch_id:, processing_status: :in_progress, results: [])
      @batches = FakeBatches.new(
        batch_id: batch_id,
        processing_status: processing_status,
        results: results
      )
    end
  end

  class FakeAnthropicClient
    attr_reader :api_key, :messages

    def initialize(api_key:, batch_id: BATCH_ID, processing_status: :in_progress, results: [])
      @api_key  = api_key
      @messages = FakeMessages.new(
        batch_id: batch_id,
        processing_status: processing_status,
        results: results
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def make_client(batch_id: BATCH_ID, processing_status: :in_progress, results: [])
    fake = FakeAnthropicClient.new(
      api_key: "test-key",
      batch_id: batch_id,
      processing_status: processing_status,
      results: results
    )
    ClaudeBatchClient.new(client: fake)
  end

  # ---------------------------------------------------------------------------
  # submit_batch
  # ---------------------------------------------------------------------------

  test "submit_batch passes requests to Anthropic and returns batch with id" do
    client = make_client
    requests = [
      { custom_id: "asset-abc", params: { model: "claude-opus-4-7", max_tokens: 100, messages: [] } }
    ]
    result = client.submit_batch(requests: requests)

    assert_equal BATCH_ID, result.id
    assert_equal requests,
                 client.instance_variable_get(:@client).messages.batches.last_create_params[:requests]
  end

  test "submit_batch with empty requests array succeeds" do
    client = make_client
    result = client.submit_batch(requests: [])
    assert_equal BATCH_ID, result.id
  end

  # ---------------------------------------------------------------------------
  # retrieve
  # ---------------------------------------------------------------------------

  test "retrieve returns batch with given id" do
    client = make_client(processing_status: :ended)
    result = client.retrieve(batch_id: BATCH_ID)

    assert_equal BATCH_ID, result.id
    assert_equal :ended, result.processing_status
    assert_equal BATCH_ID,
                 client.instance_variable_get(:@client).messages.batches.last_retrieved_id
  end

  # ---------------------------------------------------------------------------
  # results_each
  # ---------------------------------------------------------------------------

  test "results_each yields each item from results_streaming" do
    fake_result = OpenStruct.new(custom_id: "asset-abc", result: OpenStruct.new(type: "succeeded"))
    client  = make_client(results: [ fake_result ])
    yielded = []

    client.results_each(batch_id: BATCH_ID) { |r| yielded << r }

    assert_equal 1, yielded.size
    assert_equal "asset-abc", yielded.first.custom_id
  end

  test "results_each with no results yields nothing" do
    client  = make_client(results: [])
    yielded = []
    client.results_each(batch_id: BATCH_ID) { |r| yielded << r }
    assert_empty yielded
  end

  # When the SDK's decode_content falls through to the StringIO branch
  # (content-type mismatch), JsonLStream yields raw JSON line strings.
  # results_each must parse and coerce them into MessageBatchIndividualResponse.
  test "results_each coerces raw JSONL string lines when SDK yields strings" do
    raw_lines = [
      "{\"custom_id\":\"asset-abc\",\"result\":{\"type\":\"errored\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}}",
      "",  # empty line should be skipped
      "{\"custom_id\":\"asset-xyz\",\"result\":{\"type\":\"errored\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}}"
    ]
    client  = make_client(results: raw_lines)
    yielded = []

    client.results_each(batch_id: BATCH_ID) { |r| yielded << r }

    assert_equal 2, yielded.size
    assert_equal "asset-abc", yielded.first.custom_id
    assert_equal "asset-xyz", yielded.last.custom_id
    assert_equal :errored, yielded.first.result.type
  end
end
