# frozen_string_literal: true

require "test_helper"

class PilotEventRecorderTest < ActiveSupport::TestCase
  setup do
    PilotEvent.delete_all
    @ts = Time.zone.local(2026, 8, 25, 12, 0, 0)
  end

  test "inserts the event without callbacks, validations, or broadcasts" do
    original = PilotEvent.method(:insert!)
    insert_kwargs = nil
    PilotEvent.define_singleton_method(:insert!) do |*args, **kwargs|
      insert_kwargs = kwargs
      original.call(*args, **kwargs)
    end

    travel_to(@ts) do
      assert_difference("PilotEvent.count", 1) do
        PilotEventRecorder.record("interaction_completed", {
          event: "interaction_completed",
          ts: @ts.iso8601,
          account_id: 3,
          user_id: 6,
          conversation_session_id: 5,
          correlation_id: "query:abc",
          outcome: "answered"
        })
      end
    end

    row = PilotEvent.last
    assert_equal "interaction_completed", row.event
    assert_equal "query:abc", row.correlation_id
    assert_equal 3, row.account_id
    assert_equal 6, row.user_id
    assert_equal 5, row.conversation_session_id
    assert_equal @ts, row.occurred_at
    assert_equal "answered", row.payload.deep_symbolize_keys[:outcome]
    assert_equal true, insert_kwargs[:record_timestamps]
  ensure
    PilotEvent.define_singleton_method(:insert!) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  test "uses the event ts as occurred_at rather than the insert time" do
    event_ts = Time.zone.local(2026, 8, 10, 16, 5, 0)

    travel_to(Time.zone.local(2026, 8, 25, 20, 0, 0)) do
      PilotEventRecorder.record("evidence_route", {
        event: "evidence_route",
        ts: event_ts.iso8601,
        correlation_id: "query:old"
      })
    end

    assert_equal event_ts, PilotEvent.last.occurred_at
  end

  test "kill-switch PILOT_EVENTS_PERSIST=false skips the INSERT" do
    previous = ENV["PILOT_EVENTS_PERSIST"]
    ENV["PILOT_EVENTS_PERSIST"] = "false"

    assert_no_difference("PilotEvent.count") do
      PilotEventRecorder.record("interaction_completed", {
        event: "interaction_completed", ts: @ts.iso8601, correlation_id: "query:off"
      })
    end
  ensure
    previous.nil? ? ENV.delete("PILOT_EVENTS_PERSIST") : ENV["PILOT_EVENTS_PERSIST"] = previous
  end

  test "an INSERT failure never raises into the caller" do
    original = PilotEvent.method(:insert!)
    PilotEvent.define_singleton_method(:insert!) { |*_args, **_kwargs| raise "db down" }

    assert_nothing_raised do
      PilotEventRecorder.record("photo_failed", { event: "photo_failed", ts: @ts.iso8601 })
    end
  ensure
    PilotEvent.define_singleton_method(:insert!) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  test "duplicate rows are tolerated because there is no unique key" do
    payload = {
      event: "interaction_completed",
      ts: @ts.iso8601,
      correlation_id: "query:dup",
      outcome: "answered"
    }

    2.times { PilotEventRecorder.record("interaction_completed", payload) }

    assert_equal 2, PilotEvent.where(event: "interaction_completed", correlation_id: "query:dup").count
  end
end
