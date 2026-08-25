# frozen_string_literal: true

require "test_helper"

class PilotEventTest < ActiveSupport::TestCase
  setup do
    PilotEvent.delete_all
    @range = Time.zone.local(2026, 8, 25).all_day
  end

  test "hot_path_rows filters by occurred_at and user_id via pluck" do
    in_range = Time.zone.local(2026, 8, 25, 12)
    out_of_range = Time.zone.local(2026, 8, 24, 12)

    insert_event("interaction_completed", occurred_at: in_range, user_id: 1, correlation_id: "query:keep")
    insert_event("interaction_completed", occurred_at: in_range, user_id: 2, correlation_id: "query:other-user")
    insert_event("interaction_completed", occurred_at: out_of_range, user_id: 1, correlation_id: "query:yesterday")

    rows = PilotEvent.hot_path_rows(range: @range, user_ids: [ 1 ])

    assert_equal 1, rows.size
    event, correlation_id, _account_id, user_id, _session_id, occurred_at, payload = rows.first
    assert_equal "interaction_completed", event
    assert_equal "query:keep", correlation_id
    assert_equal 1, user_id
    assert_equal in_range, occurred_at
    assert_equal "query:keep", payload.deep_symbolize_keys[:correlation_id]
  end

  test "hot_path_rows without user_ids returns every event in the range ordered by occurred_at" do
    later = Time.zone.local(2026, 8, 25, 15)
    earlier = Time.zone.local(2026, 8, 25, 9)
    insert_event("rag_quality", occurred_at: later, user_id: 2, correlation_id: "query:b")
    insert_event("interaction_completed", occurred_at: earlier, user_id: 1, correlation_id: "query:a")

    rows = PilotEvent.hot_path_rows(range: @range)

    assert_equal "query:a", rows.first[1]
    assert_equal "query:b", rows.last[1]
  end

  private

  def insert_event(event, occurred_at:, user_id:, correlation_id:)
    PilotEvent.insert!(
      {
        event: event,
        correlation_id: correlation_id,
        user_id: user_id,
        account_id: 3,
        occurred_at: occurred_at,
        payload: { event: event, ts: occurred_at.iso8601, correlation_id: correlation_id, user_id: user_id }
      },
      record_timestamps: true
    )
  end
end
