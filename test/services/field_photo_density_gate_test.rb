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
end
