# frozen_string_literal: true

require "test_helper"

# Fixed rule 12: a certifier's dictation goes to that certifier and nobody else.
# The failure this guards against is not cross-account leakage — the host
# already handles that — but the colleague in the same account, which is
# exactly what reusing KbSyncChannel's account-wide stream would have caused.
class VoiceDictationChannelTest < ActionCable::Channel::TestCase
  def setup
    @account   = accounts(:legacy)
    @user      = users(:one)
    @colleague = User.create!(email: "vdc-#{SecureRandom.hex(4)}@example.com",
                              password: "password123", account: @account)
    @outsider  = users(:two) # a different account in the fixtures
  end

  test "subscribes to the stream of the current user only" do
    stub_connection current_user: @user
    subscribe

    assert subscription.confirmed?
    assert_has_stream "user:#{@user.id}:voice_dictations"
    assert_not_includes subscription.streams, "user:#{@colleague.id}:voice_dictations"
  end

  # The regression this whole channel exists for.
  test "it never subscribes to an account-wide stream" do
    stub_connection current_user: @user
    subscribe

    assert_not_includes subscription.streams, "account:#{@account.id}:kb_sync"
    subscription.streams.each do |stream|
      assert_not_includes stream, "account:", "an account-scoped stream reaches colleagues"
    end
  end

  test "a colleague in the same account is not delivered another certifier's dictation" do
    stub_connection current_user: @colleague
    subscribe
    colleague_stream = VoiceDictationBroadcaster.channel_for(@colleague.id)

    ActionCable.server.broadcast(
      VoiceDictationBroadcaster.channel_for(@user.id),
      { voice_dictation_id: 1, status: "transcribed", transcript: "La puerta roza." }
    )

    assert_empty broadcasts(colleague_stream),
                 "one certifier's field notes must not appear on a colleague's screen"
  end

  test "a user of another account is not delivered it either" do
    stub_connection current_user: @outsider
    subscribe

    ActionCable.server.broadcast(
      VoiceDictationBroadcaster.channel_for(@user.id), { voice_dictation_id: 1 }
    )

    assert_empty broadcasts(VoiceDictationBroadcaster.channel_for(@outsider.id))
  end

  test "unsubscribing stops the stream" do
    stub_connection current_user: @user
    subscribe
    assert subscription.confirmed?

    unsubscribe
    assert_no_streams
  end
end
