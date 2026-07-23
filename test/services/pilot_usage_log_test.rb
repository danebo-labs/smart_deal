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
end
