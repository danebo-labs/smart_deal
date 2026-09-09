# frozen_string_literal: true

require "test_helper"

# Intake is where a double tap with gloves on a bad connection either becomes
# one billed transcription or two. Everything here is about that: the bytes go
# up first, the row is keyed by content, and the job is enqueued exactly once
# per distinct audio per report (section 2.2, gap 5).
class VoiceDictationIntakeTest < ActiveJob::TestCase
  class FakeS3
    attr_reader :uploads

    def initialize(fail_upload: false)
      @fail_upload = fail_upload
      @uploads     = []
    end

    def upload_binary(key, binary, content_type)
      return nil if @fail_upload

      @uploads << { key: key, bytes: binary.bytesize, content_type: content_type }
      key
    end
  end

  def setup
    @account = accounts(:legacy)
    @user    = users(:one)
    @report  = certification_reports(:torre_amunategui)
    @audio   = "OggS\x00\x02field-recording".b
  end

  # Blinds only the pre-insert lookup, so the insert hits the unique index and
  # the rescue path has to recover the winner's row on its own.
  def with_dedup_miss
    original = VoiceDictationIntake.method(:find_existing)
    lookups  = 0
    define_dedup_lookup { |*args| (lookups += 1) == 1 ? nil : original.call(*args) }
    yield
  ensure
    define_dedup_lookup { |*args| original.call(*args) }
  end

  def define_dedup_lookup(&implementation)
    VoiceDictationIntake.define_singleton_method(:find_existing, &implementation)
    VoiceDictationIntake.singleton_class.send(:private, :find_existing)
  end

  def intake(s3:, binary: @audio, **kwargs)
    defaults = { account_id: @account.id, user_id: @user.id, binary: binary,
                 content_type: "audio/webm", certification_report_id: @report.id }

    VoiceDictationIntake.call(**defaults.merge(kwargs), s3: s3)
  end

  test "uploads the audio, creates the dictation and enqueues exactly one transcription" do
    s3 = FakeS3.new

    record = nil
    assert_enqueued_jobs 1, only: TranscriptionJob do
      record = intake(s3: s3)
    end

    assert_equal Digest::SHA256.hexdigest(@audio), record.sha256
    assert_equal @audio.bytesize, record.byte_size
    assert_equal "pending", record.status
    assert_equal @account.id, record.account_id
    assert_equal @user.id, record.user_id
    assert_equal [ record.s3_key_audio ], s3.uploads.pluck(:key)
  end

  test "the audio lands under the account-scoped prefix and never where the Knowledge Base reads" do
    record = intake(s3: FakeS3.new)

    assert_equal "voice_dictations/#{@account.id}/#{record.sha256}/audio.webm", record.s3_key_audio
    assert_not_includes record.s3_key_audio, "bulk_chunks"
  end

  test "the extension follows the recorded filename when the browser gives one" do
    record = intake(s3: FakeS3.new, filename: "dictado.m4a")

    assert record.s3_key_audio.end_with?("audio.m4a")
  end

  # The double tap. One row, one upload, one job — because a second job is a
  # second invoice.
  test "the same audio twice on the same report is one dictation and one billed call" do
    s3 = FakeS3.new

    first = nil
    second = nil
    assert_enqueued_jobs 1, only: TranscriptionJob do
      first  = intake(s3: s3)
      second = intake(s3: s3)
    end

    assert_equal first.id, second.id
    assert_equal 1, s3.uploads.size, "the second tap must not re-upload the audio either"
  end

  # Deduplicating globally by account would make it impossible to file the same
  # recording against a second report, which is a legitimate thing to do.
  test "the same audio on a different report is a new dictation of its own" do
    other = CertificationReport.create!(account: @account, user: @user, building_name: "Otro edificio")

    first  = intake(s3: FakeS3.new)
    second = intake(s3: FakeS3.new, certification_report_id: other.id)

    assert_not_equal first.id, second.id
    assert_equal 2, VoiceDictation.where(sha256: first.sha256).count
  end

  test "a report-less dictation still deduplicates" do
    s3 = FakeS3.new

    first  = intake(s3: s3, certification_report_id: nil)
    second = intake(s3: s3, certification_report_id: nil)

    assert_equal first.id, second.id
  end

  # Losing the race to a concurrent upload must not enqueue a second job: that
  # is precisely the extra provider call the claim exists to prevent.
  test "losing the uniqueness race returns the winner's row without enqueueing again" do
    winner = intake(s3: FakeS3.new)

    # The row appears between the lookup and the insert, which is what a
    # concurrent request looks like from here.
    with_dedup_miss do
      assert_no_enqueued_jobs only: TranscriptionJob do
        assert_equal winner.id, intake(s3: FakeS3.new).id
      end
    end
  end

  # No row may ever point at bytes that are not in the bucket, or the
  # transcription job would claim it and fail against a missing object.
  test "a failed upload creates no dictation and no job" do
    assert_no_enqueued_jobs only: TranscriptionJob do
      assert_no_difference -> { VoiceDictation.count } do
        assert_nil intake(s3: FakeS3.new(fail_upload: true))
      end
    end
  end

  test "unusable arguments are refused before anything is uploaded" do
    s3 = FakeS3.new

    assert_nil intake(s3: s3, binary: "")
    assert_nil intake(s3: s3, account_id: nil)
    assert_nil intake(s3: s3, user_id: nil)
    assert_empty s3.uploads
  end

  test "the duration measured at recording time is stored for the providers that report none" do
    record = intake(s3: FakeS3.new, duration_seconds: 137)

    assert_equal 137, record.duration_seconds
  end
end
