# frozen_string_literal: true

require "test_helper"

class FieldPhotoDensityGateTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @orig_haiku_flag = ENV["FIELD_PHOTO_HAIKU_GATE_ENABLED"]
    ENV["FIELD_PHOTO_HAIKU_GATE_ENABLED"] = "false"
  end

  teardown do
    ENV["FIELD_PHOTO_HAIKU_GATE_ENABLED"] = @orig_haiku_flag
  end

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

  test "Haiku gate enabled: overrides to :opus when force_opus true" do
    ENV["FIELD_PHOTO_HAIKU_GATE_ENABLED"] = "true"
    small_binary = "\xFF\xD8" + ("x" * 100)

    fake_response_text = '{"force_opus": true}'
    fake_content       = [ OpenStruct.new(type: "text", text: fake_response_text) ]
    fake_response      = OpenStruct.new(content: fake_content)
    fake_messages      = Object.new
    fake_messages.define_singleton_method(:create) { |**| fake_response }
    fake_client        = OpenStruct.new(messages: fake_messages)

    orig_new = Anthropic::Client.method(:new)
    Anthropic::Client.define_singleton_method(:new) { |**| fake_client }

    route = FieldPhotoDensityGate.decide(
      binary:       small_binary,
      content_type: "image/jpeg",
      filename:     "borderline.jpg"
    )
    assert_equal :opus, route
  ensure
    Anthropic::Client.define_singleton_method(:new, orig_new)
  end

  test "Haiku gate enabled: keeps :sonnet when force_opus false" do
    ENV["FIELD_PHOTO_HAIKU_GATE_ENABLED"] = "true"
    small_binary = "\xFF\xD8" + ("x" * 100)

    fake_response_text = '{"force_opus": false}'
    fake_content       = [ OpenStruct.new(type: "text", text: fake_response_text) ]
    fake_response      = OpenStruct.new(content: fake_content)
    fake_messages      = Object.new
    fake_messages.define_singleton_method(:create) { |**| fake_response }
    fake_client        = OpenStruct.new(messages: fake_messages)

    orig_new = Anthropic::Client.method(:new)
    Anthropic::Client.define_singleton_method(:new) { |**| fake_client }

    route = FieldPhotoDensityGate.decide(
      binary:       small_binary,
      content_type: "image/jpeg",
      filename:     "normal.jpg"
    )
    assert_equal :sonnet, route
  ensure
    Anthropic::Client.define_singleton_method(:new, orig_new)
  end

  test "Haiku gate error falls back to heuristic route" do
    ENV["FIELD_PHOTO_HAIKU_GATE_ENABLED"] = "true"
    small_binary = "\xFF\xD8" + ("x" * 100)

    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**| raise "network error" }
    fake_client   = OpenStruct.new(messages: fake_messages)

    orig_new = Anthropic::Client.method(:new)
    Anthropic::Client.define_singleton_method(:new) { |**| fake_client }

    route = FieldPhotoDensityGate.decide(
      binary:       small_binary,
      content_type: "image/jpeg",
      filename:     "normal.jpg"
    )
    assert_equal :sonnet, route
  ensure
    Anthropic::Client.define_singleton_method(:new, orig_new)
  end
end
