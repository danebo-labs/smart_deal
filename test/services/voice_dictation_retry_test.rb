# frozen_string_literal: true

require "test_helper"

# The only automatic thing about a retry is that there is none: a failed
# dictation is re-sent to the provider exactly once per explicit human tap, and
# never once its audio is gone (fixed rule 13, T5).
class VoiceDictationRetryTest < ActiveJob::TestCase
  def setup
    @account = accounts(:legacy)
    @user    = users(:one)
    @report  = certification_reports(:torre_amunategui)
  end

  def dictation(status: :failed, **attrs)
    sha = SecureRandom.hex(32)
    VoiceDictation.create!(
      { account: @account, user: @user, certification_report: @report, sha256: sha,
        content_type: "audio/webm", status: status, failure_reason: "ProviderError: 429",
        s3_key_audio: "voice_dictations/#{@account.id}/#{sha}/audio.webm" }.merge(attrs)
    )
  end

  test "reopens a failed dictation and enqueues exactly one transcription" do
    record = dictation

    assert_enqueued_with(job: TranscriptionJob, args: [ { voice_dictation_id: record.id } ]) do
      assert VoiceDictationRetry.call(record)
    end

    record.reload
    assert_equal "pending", record.status
    assert_nil record.failure_reason
  end

  test "a second tap on the same failed dictation enqueues nothing more" do
    record = dictation

    assert_enqueued_jobs 1, only: TranscriptionJob do
      assert VoiceDictationRetry.call(record)
      assert_not VoiceDictationRetry.call(record)
    end
  end

  test "refuses once the audio was purged, so the UI offers re-recording instead" do
    purged = dictation(audio_purged_at: Time.current, s3_key_audio: nil)

    assert_no_enqueued_jobs only: TranscriptionJob do
      assert_not VoiceDictationRetry.call(purged)
    end
    assert_equal "failed", purged.reload.status
  end

  test "refuses every state other than failed" do
    %i[pending transcribing transcribed confirmed].each do |status|
      record = dictation(status: status)
      assert_no_enqueued_jobs only: TranscriptionJob do
        assert_not VoiceDictationRetry.call(record), "retry from #{status} must be refused"
      end
    end
  end
end
