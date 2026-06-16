# frozen_string_literal: true

require "test_helper"

class FieldPhotoDensityGateTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  test "small JPEG routes to :sonnet" do
    small_binary = "\xFF\xD8" + ("x" * 100)
    route = FieldPhotoDensityGate.decide(
      binary:       small_binary,
      content_type: "image/jpeg",
      filename:     "motor.jpg"
    )
    assert_equal :sonnet, route
  end

  test "binary >= LARGE_PHOTO_THRESHOLD routes to :opus" do
    large_binary = "x" * FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD
    route = FieldPhotoDensityGate.decide(
      binary:       large_binary,
      content_type: "image/jpeg",
      filename:     "dense_scan.jpg"
    )
    assert_equal :opus, route
  end

  test "binary exactly at threshold routes to :opus" do
    boundary_binary = "x" * FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD
    route = FieldPhotoDensityGate.decide(
      binary:       boundary_binary,
      content_type: "image/png",
      filename:     "scan.png"
    )
    assert_equal :opus, route
  end

  # ── Gate 9R O1′ prep: telemetry without changing the decision ───────────────

  def capture_info_logs
    logged = []
    original = Rails.logger.method(:info)
    Rails.logger.define_singleton_method(:info) { |msg = nil, &blk| logged << (msg || blk&.call).to_s }
    yield
    logged
  ensure
    Rails.logger.define_singleton_method(:info) { |msg = nil, &blk| original.call(msg, &blk) }
  end

  test "emits a field_photo_gate event with bytes, route and format metadata" do
    binary = Vips::Image.black(120, 80).write_to_buffer(".jpg")

    logged = capture_info_logs do
      FieldPhotoDensityGate.decide(binary: binary, content_type: "image/jpeg", filename: "motor.jpg")
    end

    line = logged.find { |l| l.include?("field_photo_gate") }
    assert line, "expected a field_photo_gate telemetry event"

    event = JSON.parse(line)
    assert_equal "motor.jpg",      event["filename"]
    assert_equal "sonnet",         event["route"]
    assert_equal binary.bytesize,  event["bytes"]
    assert_equal FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD, event["threshold"]
    assert_equal 120, event["width"]
    assert_equal 80, event["height"]
    assert_equal "image/jpeg", event["content_type"]
  end

  test "emits model key matching MODEL_TEXT for :sonnet route" do
    binary = "\xFF\xD8".b + ("x" * 100)
    logged = capture_info_logs do
      FieldPhotoDensityGate.decide(binary: binary, content_type: "image/jpeg", filename: "motor.jpg")
    end
    event = JSON.parse(logged.find { |l| l.include?("field_photo_gate") })
    assert_equal BatchChunkingPrompt::MODEL_TEXT, event["model"]
  end

  test "emits model key matching MODEL_MULTIMODAL for :opus route" do
    binary = "x" * FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD
    logged = capture_info_logs do
      FieldPhotoDensityGate.decide(binary: binary, content_type: "image/jpeg", filename: "scan.jpg")
    end
    event = JSON.parse(logged.find { |l| l.include?("field_photo_gate") })
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, event["model"]
  end

  test "emits correlation_id when supplied" do
    binary = "\xFF\xD8".b + ("x" * 100)
    cid    = "ingest:aabb001122cc"
    logged = capture_info_logs do
      FieldPhotoDensityGate.decide(binary: binary, content_type: "image/jpeg",
                                   filename: "motor.jpg", correlation_id: cid)
    end
    event = JSON.parse(logged.find { |l| l.include?("field_photo_gate") })
    assert_equal cid, event["correlation_id"]
  end

  test "omits correlation_id key when not supplied" do
    binary = "\xFF\xD8".b + ("x" * 100)
    logged = capture_info_logs do
      FieldPhotoDensityGate.decide(binary: binary, content_type: "image/jpeg", filename: "motor.jpg")
    end
    event = JSON.parse(logged.find { |l| l.include?("field_photo_gate") })
    assert_nil event["correlation_id"], "correlation_id must be absent from web/no-sha callers"
  end

  test "telemetry failure never changes the routing decision" do
    original = Rails.logger.method(:info)
    Rails.logger.define_singleton_method(:info) { |*| raise "logger down" }

    route = FieldPhotoDensityGate.decide(
      binary:       "x" * FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD,
      content_type: "image/jpeg",
      filename:     "scan.jpg"
    )
    assert_equal :opus, route
  ensure
    Rails.logger.define_singleton_method(:info) { |msg = nil, &blk| original.call(msg, &blk) }
  end
end
