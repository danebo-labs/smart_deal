# frozen_string_literal: true

require "test_helper"

class VoiceDictationBroadcasterTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  def setup
    @account = accounts(:legacy)
    @user    = users(:one)
    @report  = certification_reports(:torre_amunategui)
  end

  def dictation(**attrs)
    sha = SecureRandom.hex(32)
    VoiceDictation.create!(
      { account: @account, user: @user, certification_report: @report, sha256: sha,
        content_type: "audio/webm", status: :transcribed,
        transcript_raw: "La puerta de cabina roza al cerrar." }.merge(attrs)
    )
  end

  test "the stream is keyed by user, not by account" do
    assert_equal "user:42:voice_dictations", VoiceDictationBroadcaster.channel_for(42)
  end

  test "a transcript is delivered with enough context for the UI to place it" do
    record = dictation

    messages = capture_broadcasts(VoiceDictationBroadcaster.channel_for(@user.id)) do
      VoiceDictationBroadcaster.transcribed(record)
    end

    assert_equal "transcribed", messages.sole["status"]
    assert_equal record.id, messages.sole["voice_dictation_id"]
    assert_equal @report.id, messages.sole["certification_report_id"]
    assert_equal "La puerta de cabina roza al cerrar.", messages.sole["transcript"]
  end

  # A twenty minute dictation is a lot of text to push through the cable when
  # the editable panel reads the full transcript from the database anyway.
  test "a long transcript is capped rather than streamed whole" do
    record = dictation(transcript_raw: "a" * 5_000)

    messages = capture_broadcasts(VoiceDictationBroadcaster.channel_for(@user.id)) do
      VoiceDictationBroadcaster.transcribed(record)
    end

    assert_equal VoiceDictationBroadcaster::TRANSCRIPT_PREVIEW_LIMIT,
                 messages.sole["transcript"].length
  end

  test "a failure carries a truncated reason" do
    record = dictation(status: :failed)

    messages = capture_broadcasts(VoiceDictationBroadcaster.channel_for(@user.id)) do
      VoiceDictationBroadcaster.failed(record, reason: "ProviderError: #{'x' * 400}")
    end

    assert_equal "failed", messages.sole["status"]
    assert_equal 250, messages.sole["reason"].length
  end

  test "nothing is delivered to another user of the same account" do
    record    = dictation
    colleague = User.create!(email: "vdb-#{SecureRandom.hex(4)}@example.com",
                             password: "password123", account: @account)

    assert_no_broadcasts(VoiceDictationBroadcaster.channel_for(colleague.id)) do
      VoiceDictationBroadcaster.transcribed(record)
      VoiceDictationBroadcaster.failed(record, reason: "boom")
    end
  end
end
