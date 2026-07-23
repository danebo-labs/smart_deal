# frozen_string_literal: true

require "test_helper"

class ClaudeBatchSubmissionServiceTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :groups

    def initialize
      @groups = []
    end

    def submit_batch(requests:)
      @groups << requests
      OpenStruct.new(id: "batch_#{groups.size}")
    end
  end

  def item(id, bytes, cleanup_log:)
    ClaudeBatchRequestItem.new(
      custom_id: id,
      byte_size: bytes,
      build: -> { { custom_id: id, params: {} } },
      cleanup: -> { cleanup_log << id unless cleanup_log.include?(id) }
    )
  end

  test "submits bounded groups and returns every batch id" do
    cleanup_log = []
    client = FakeClient.new
    items = [
      item("p1", 6, cleanup_log: cleanup_log),
      item("p2", 6, cleanup_log: cleanup_log),
      item("p3", 4, cleanup_log: cleanup_log)
    ]

    ids = ClaudeBatchSubmissionService.new(
      batch_client: client,
      target_raw_bytes: 10,
      max_raw_bytes: 20,
      max_requests: 10
    ).submit!(items)

    assert_equal %w[batch_1 batch_2], ids
    assert_equal [ %w[p1], %w[p2 p3] ], client.groups.map { |group| group.pluck(:custom_id) }
    assert_equal %w[p1 p2 p3], cleanup_log.sort
  end

  test "also slices by request count" do
    cleanup_log = []
    client = FakeClient.new
    items = 3.times.map { |index| item("p#{index + 1}", 1, cleanup_log: cleanup_log) }

    ClaudeBatchSubmissionService.new(
      batch_client: client,
      target_raw_bytes: 100,
      max_raw_bytes: 100,
      max_requests: 2
    ).submit!(items)

    assert_equal [ 2, 1 ], client.groups.map(&:size)
  end

  test "guardrail rejects a single oversized request before submission and cleans every item" do
    cleanup_log = []
    client = FakeClient.new
    items = [
      item("ok", 5, cleanup_log: cleanup_log),
      item("too_large", 21, cleanup_log: cleanup_log)
    ]

    error = assert_raises(ClaudeBatchSubmissionService::PayloadTooLargeError) do
      ClaudeBatchSubmissionService.new(
        batch_client: client,
        target_raw_bytes: 10,
        max_raw_bytes: 20
      ).submit!(items)
    end

    assert_equal "too_large", error.custom_id
    assert_empty client.groups
    assert_equal %w[ok too_large], cleanup_log.sort
  end
end
