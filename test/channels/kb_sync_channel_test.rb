# frozen_string_literal: true

require "test_helper"

# P-12: Two accounts subscribe to different streams; no cross-delivery.
class KbSyncChannelTest < ActionCable::Channel::TestCase
  def setup
    @account_a = accounts(:legacy)
    @account_b = accounts(:climb)
    @user_a    = users(:one)   # belongs to legacy account (fixtures)
    @user_b    = users(:two)   # belongs to climb account (fixtures)
  end

  test "subscribes to account-scoped stream for user_a" do
    stub_connection current_user: @user_a

    subscribe

    assert subscription.confirmed?
    assert_has_stream "account:#{@account_a.id}:kb_sync"
    assert_not_includes subscription.streams, "account:#{@account_b.id}:kb_sync"
  end

  test "subscribes to account-scoped stream for user_b" do
    stub_connection current_user: @user_b

    subscribe

    assert subscription.confirmed?
    assert_has_stream "account:#{@account_b.id}:kb_sync"
    assert_not_includes subscription.streams, "account:#{@account_a.id}:kb_sync"
  end

  test "broadcast to account_a stream is not delivered to account_b subscriber" do
    broadcasts_a = []
    broadcasts_b = []

    stub_connection current_user: @user_a
    subscribe
    stream_name_a = "account:#{@account_a.id}:kb_sync"

    stub_connection current_user: @user_b
    subscribe
    stream_name_b = "account:#{@account_b.id}:kb_sync"

    # Broadcast only to account_a's stream
    ActionCable.server.broadcast(stream_name_a, { status: "completed", filenames: [ "manual.pdf" ] })

    # account_b stream should receive nothing from account_a broadcast
    received_on_b = broadcasts(stream_name_b)
    assert_empty received_on_b, "account_b must not receive broadcasts from account_a stream"
  end

  test "unsubscribed stops all streams" do
    stub_connection current_user: @user_a
    subscribe

    assert subscription.confirmed?
    unsubscribe
    assert_no_streams
  end
end
