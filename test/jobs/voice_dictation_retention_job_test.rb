# frozen_string_literal: true

require "test_helper"

# Fixed rule 10 with the constraint of fixed rule 11 on top: audio that is done
# with gets deleted, audio that is unfinished work never does.
#
# The lesson of the Fase 0 closing block is baked into how these tests are
# written. A test that only asserts "the unconfirmed dictation still has its
# audio" passes even with the exclusion deleted from the query, because the
# per-row re-check rescues it. So the assertions are on the counters: `kept`
# proves the query saw it and skipped it, and `aborted == 0` proves the audio
# was protected by layer one rather than by layer two.
class VoiceDictationRetentionJobTest < ActiveJob::TestCase
  class FakeS3
    attr_reader :prefixes

    def initialize(deleted: 1)
      @deleted  = deleted
      @prefixes = []
    end

    def delete_prefix(prefix)
      @prefixes << prefix
      @deleted
    end
  end

  def with_fake_s3(fake)
    original = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { |*_args, **_kwargs| fake }
    yield
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| original.call(*a, **kw) }
  end

  def setup
    @account = accounts(:legacy)
    @user    = users(:one)
    @report  = certification_reports(:torre_amunategui)
  end

  def dictation(status:, created_at: 200.days.ago, **attrs)
    sha = SecureRandom.hex(32)
    VoiceDictation.create!(
      { account: @account, user: @user, certification_report: @report, sha256: sha,
        content_type: "audio/webm", status: status, provider: "amazon_transcribe",
        duration_seconds: 42, cost_estimate_usd: 0.0168, created_at: created_at,
        s3_key_audio: "voice_dictations/#{@account.id}/#{sha}/audio.webm" }.merge(attrs)
    )
  end

  def run_job(fake = FakeS3.new)
    result = nil
    with_fake_s3(fake) { result = VoiceDictationRetentionJob.perform_now }
    result
  end

  # --- what gets purged ---

  test "audio of a terminal dictation past the window is deleted from the bucket" do
    confirmed = dictation(status: :confirmed)
    failed    = dictation(status: :failed)
    fake      = FakeS3.new

    result = run_job(fake)

    assert_equal 2, result[:purged]
    assert_equal 0, result[:aborted]
    [ confirmed, failed ].each do |record|
      assert_includes fake.prefixes,
                      VoiceDictationAudio.prefix_for(account_id: @account.id, sha256: record.sha256)
    end
  end

  # The deviation from "row before S3" that the design block documents:
  # destroying the row would take the finding's traceability and the cost
  # telemetry Fase 6 needs with it.
  test "the row survives the purge, with its cost telemetry and its finding link" do
    record  = dictation(status: :confirmed)
    finding = InspectionFinding.create!(certification_report: @report, body: "texto",
                                        voice_dictation: record)

    run_job

    record.reload
    assert_nil record.s3_key_audio
    assert_not_nil record.audio_purged_at
    assert_not record.audio_available?
    assert_equal 0.0168, record.cost_estimate_usd.to_f
    assert_equal "amazon_transcribe", record.provider
    assert_equal record.id, finding.reload.voice_dictation_id
  end

  test "purging is idempotent, so a second nightly run deletes nothing again" do
    dictation(status: :confirmed)

    assert_equal 1, run_job[:purged]

    fake = FakeS3.new
    assert_equal 0, run_job(fake)[:purged]
    assert_empty fake.prefixes
  end

  # --- what never gets purged (fixed rule 11) ---

  test "audio of an unfinished dictation is protected by the query, not by the fallback guard" do
    kept = VoiceDictation::IN_PROGRESS_STATUSES.map { |status| dictation(status: status) }
    fake = FakeS3.new

    result = run_job(fake)

    assert_equal 0, result[:purged]
    assert_equal kept.size, result[:kept]
    assert_equal 0, result[:aborted],
                 "aborted > 0 means the batch query selected audio it should never have loaded"
    assert_empty fake.prefixes
    kept.each { |record| assert record.reload.audio_available? }
  end

  # The specific case of fixed rule 11: a transcript the certifier read but
  # never confirmed is work in progress, and they may still reopen the report.
  test "a transcribed but unconfirmed dictation keeps its audio no matter how old" do
    record = dictation(status: :transcribed, created_at: 3.years.ago)

    assert_equal 0, run_job[:purged]
    assert record.reload.audio_available?
  end

  test "a terminal dictation inside the window is left alone" do
    record = dictation(status: :confirmed, created_at: 2.days.ago)

    assert_equal 0, run_job[:purged]
    assert record.reload.audio_available?
  end

  test "the window is configurable" do
    record = dictation(status: :confirmed, created_at: 10.days.ago)

    assert_equal 0, run_job[:purged]

    ENV["VOICE_DICTATION_RETENTION_DAYS"] = "7"
    assert_equal 1, run_job[:purged]
    assert_not record.reload.audio_available?
  ensure
    ENV.delete("VOICE_DICTATION_RETENTION_DAYS")
  end

  # --- the second layer, exercised on purpose ---

  # Layer two is unreachable through the public interface (the query never hands
  # it a non-terminal row), so it is exercised directly: a dictation that left a
  # terminal state after the batch was loaded — an explicit human retry, T5 —
  # must not have its audio deleted.
  test "the per-row re-check refuses a dictation that stopped being terminal mid-run" do
    record = dictation(status: :failed)
    VoiceDictation.reopen_failed!(id: record.id)

    assert_not VoiceDictation.claim_audio_purge!(id: record.id)
    assert record.reload.audio_available?
  end

  test "an S3 delete that removed nothing still leaves the row purged rather than half-done" do
    record = dictation(status: :confirmed)

    result = run_job(FakeS3.new(deleted: 0))

    assert_equal 1, result[:purged]
    assert_nil record.reload.s3_key_audio
  end

  test "a dictation whose audio was already purged is not counted or retried" do
    dictation(status: :confirmed, s3_key_audio: nil, audio_purged_at: 1.day.ago)
    fake = FakeS3.new

    result = run_job(fake)

    assert_equal 0, result[:purged]
    assert_empty fake.prefixes
  end
end
