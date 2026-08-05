# frozen_string_literal: true

require "test_helper"
require "stringio"

class PilotTelemetryReaderTest < ActiveSupport::TestCase
  setup do
    @range = Time.zone.local(2026, 7, 22).all_day
  end

  test "reads StringIO, counts invalid marker lines, and reports a missing declared role as partial" do
    io = StringIO.new(<<~LOG)
      [PILOT_USAGE] {"event":"interaction_completed","ts":"#{@range.begin.iso8601}","role":"web","user_id":1,"correlation_id":"query:1"}
      [PILOT_USAGE] invalid-json
      [RAG_QUALITY] {"ts":"#{@range.end.iso8601}","role":"web","user_id":1,"correlation_id":"query:1","evidence_present":true}
      [PILOT_AUDIT] {"ts":"#{@range.end.iso8601}","role":"web","user_id":1,"correlation_id":"query:1","type":"interaction","question":"full question","answer":"full answer"}
    LOG

    result = PilotTelemetryReader.new(
      source: io,
      range: @range,
      user_ids: [ 1 ],
      roles_declared: %w[web worker]
    ).read

    assert_equal "partial", result[:status]
    assert_equal 1, result[:invalid_lines]
    assert_equal @range.begin.iso8601, result[:first_ts]
    assert_equal @range.end.iso8601, result[:last_ts]
    assert_equal %w[web worker], result[:roles_declared]
    assert_equal [ "worker" ], result[:missing_roles]
    assert_equal 1, result[:pilot].size
    assert_equal 1, result[:quality].size
    assert_equal 1, result[:audit].size
  end

  test "returns loaded when the observed window and every declared role are covered" do
    io = StringIO.new(<<~LOG)
      [PILOT_USAGE] {"event":"interaction_completed","ts":"#{@range.begin.iso8601}","role":"web","user_id":1,"correlation_id":"query:1"}
      [PILOT_USAGE] {"event":"interaction_completed","ts":"#{@range.end.iso8601}","role":"worker","user_id":1,"correlation_id":"query:2"}
    LOG

    result = PilotTelemetryReader.new(
      source: io,
      range: @range,
      roles_declared: %w[web worker]
    ).read

    assert_equal "loaded", result[:status]
    assert_empty result[:missing_roles]
  end

  test "returns partial when the observed timestamps do not cover the requested range" do
    io = StringIO.new(
      "[PILOT_USAGE] {\"event\":\"interaction_completed\",\"ts\":\"#{@range.begin.advance(hours: 1).iso8601}\"}\n"
    )

    result = PilotTelemetryReader.new(source: io, range: @range).read

    assert_equal "partial", result[:status]
  end

  test "distinguishes logs not provided from a missing path" do
    not_provided = PilotTelemetryReader.new(source: nil, range: @range).read
    missing = PilotTelemetryReader.new(source: "/tmp/pilot-metrics-does-not-exist", range: @range).read

    assert_equal "logs_not_provided", not_provided[:status]
    assert_equal "logs_missing", missing[:status]
  end
end
