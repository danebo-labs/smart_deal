# frozen_string_literal: true

require "test_helper"

class PilotUsageLogTest < ActiveSupport::TestCase
  test "emits safe structured JSON and drops image fields" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    assert PilotUsageLog.log(
      "photo_cache_hit",
      account_id: 1,
      user_id: 2,
      correlation_id: "photo:abc",
      cost: 0,
      binary: "raw-image",
      data: Base64.strict_encode64("raw-image")
    )

    line = output.string.lines.find { |entry| entry.include?("[PILOT_USAGE]") }
    payload = JSON.parse(line.split("[PILOT_USAGE] ", 2).last)
    assert_equal "photo_cache_hit", payload["event"]
    assert_equal 2, payload["user_id"]
    assert payload["ts"].present?
    assert_not_includes line, "raw-image"
    assert_nil payload["binary"]
    assert_nil payload["data"]

    row = PilotEvent.find_by(event: "photo_cache_hit", correlation_id: "photo:abc")
    assert row, "the same whitelisted payload must be persisted"
    persisted = row.payload.deep_symbolize_keys
    assert_equal 1, persisted[:account_id]
    assert_equal 2, persisted[:user_id]
    assert_equal 0, persisted[:cost]
    assert_nil persisted[:binary]
    assert_nil persisted[:data]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "telemetry failure never raises into the product flow" do
    failing_logger = Object.new
    failing_logger.define_singleton_method(:info) { |_message| raise "logger down" }
    failing_logger.define_singleton_method(:warn) { |_message| true }
    original = Rails.logger
    Rails.logger = failing_logger

    assert_equal false, PilotUsageLog.log("photo_failed", account_id: 1)
  ensure
    Rails.logger = original
  end

  test "a persist failure still returns true after the log line is written" do
    original = PilotEvent.method(:insert!)
    PilotEvent.define_singleton_method(:insert!) { |*_args, **_kwargs| raise "db down" }

    assert_equal true, PilotUsageLog.log("photo_cache_hit", account_id: 1, user_id: 2)
  ensure
    PilotEvent.define_singleton_method(:insert!) { |*args, **kwargs| original.call(*args, **kwargs) }
  end
end
