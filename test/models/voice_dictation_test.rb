# frozen_string_literal: true

require "test_helper"

# The state machine is the deliverable of Fase 4, so these tests exercise the
# transitions directly rather than only through the job: what matters is that
# each one is a guarded compare-and-set, and that the guards refuse the cases
# fixed rule 13 says must be refused.
class VoiceDictationTest < ActiveSupport::TestCase
  class FakeS3
    attr_reader :prefixes

    def initialize
      @prefixes = []
    end

    def delete_prefix(prefix)
      @prefixes << prefix
      1
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

  def dictation(status: :pending, sha: SecureRandom.hex(32), report: @report, **attrs)
    VoiceDictation.create!(
      { account: @account, user: @user, certification_report: report,
        sha256: sha, content_type: "audio/webm",
        s3_key_audio: "voice_dictations/#{@account.id}/#{sha}/audio.webm",
        status: status }.merge(attrs)
    )
  end

  # --- shape of the machine ---

  test "declares exactly the five states of the plan, with pending as default" do
    assert_equal %w[pending transcribing transcribed failed confirmed],
                 VoiceDictation::STATUSES.values
    assert_equal "pending", VoiceDictation.new.status
  end

  test "terminal and in-progress states partition the state space" do
    assert_equal %w[confirmed failed], VoiceDictation::TERMINAL_STATUSES
    assert_equal %w[pending transcribing transcribed], VoiceDictation::IN_PROGRESS_STATUSES
    assert_empty VoiceDictation::TERMINAL_STATUSES & VoiceDictation::IN_PROGRESS_STATUSES
    assert_equal VoiceDictation::STATUSES.values.sort,
                 (VoiceDictation::TERMINAL_STATUSES + VoiceDictation::IN_PROGRESS_STATUSES).sort
  end

  # A transcript the certifier has not confirmed is unfinished work, not an
  # artefact to reclaim (fixed rule 11) — the reason `transcribed` is not
  # terminal is easy to "simplify" away later, so it is pinned here.
  test "transcribed is not terminal, so an unconfirmed transcript is never purgeable" do
    assert_not_includes VoiceDictation::TERMINAL_STATUSES, "transcribed"
    assert_includes VoiceDictation::IN_PROGRESS_STATUSES, "transcribed"
  end

  # --- T1, the claim ---

  test "claim moves pending to transcribing and returns the claim id" do
    record = dictation
    claim  = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")

    assert_not_nil claim
    record.reload
    assert_equal "transcribing", record.status
    assert_equal "openai", record.provider
    assert_equal claim, record.transcription_claim_id
    assert_not_nil record.transcribing_since
  end

  test "a second claim of a freshly claimed dictation returns nil" do
    record = dictation
    first  = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")
    second = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")

    assert_not_nil first
    assert_nil second, "only one claimant may call the provider"
    assert_equal first, record.reload.transcription_claim_id
  end

  test "claim refuses a dictation that is already transcribed, failed or confirmed" do
    %i[transcribed failed confirmed].each do |status|
      record = dictation(status: status)
      assert_nil VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai"),
                 "must not re-transcribe a dictation in #{status}"
      assert_equal status.to_s, record.reload.status
    end
  end

  test "claim clears a previous failure reason so a retried dictation is not shown as failed" do
    record = dictation(status: :failed, failure_reason: "ProviderError: boom")
    assert VoiceDictation.reopen_failed!(id: record.id)

    VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")

    assert_nil record.reload.failure_reason
  end

  # The recovery path for a worker killed mid-call: without it the audio is
  # stranded in `transcribing` forever, which fixed rule 11 forbids.
  test "a stale transcribing claim can be re-taken, and a fresh one cannot" do
    record = dictation
    VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")

    assert_nil VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai"),
               "a live claim must not be stealable"

    record.update_columns(transcribing_since: (VoiceDictation.stale_claim_minutes + 1).minutes.ago)
    retaken = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")

    assert_not_nil retaken, "a claim abandoned by a dead worker must be recoverable"
    assert_equal retaken, record.reload.transcription_claim_id
  end

  test "the stale window is configurable through STT_STALE_CLAIM_MINUTES" do
    ENV["STT_STALE_CLAIM_MINUTES"] = "5"
    assert_equal 5, VoiceDictation.stale_claim_minutes
  ensure
    ENV.delete("STT_STALE_CLAIM_MINUTES")
    assert_equal VoiceDictation::DEFAULT_STALE_CLAIM_MINUTES, VoiceDictation.stale_claim_minutes
  end

  # --- T2, the result ---

  test "recording a transcript under the live claim stores text, duration and cost" do
    record = dictation
    claim  = VoiceDictation.claim_for_transcription!(id: record.id, provider: "amazon_transcribe")

    assert VoiceDictation.record_transcript(
      id: record.id, claim_id: claim, text: "La puerta roza.",
      provider: "amazon_transcribe", duration_seconds: 42, cost_estimate_usd: 0.0168
    )

    record.reload
    assert_equal "transcribed", record.status
    assert_equal "La puerta roza.", record.transcript_raw
    assert_equal 42, record.duration_seconds
    assert_equal 0.0168, record.cost_estimate_usd.to_f
  end

  test "a transcript carrying a stale claim id writes nothing" do
    record = dictation
    VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")

    assert_not VoiceDictation.record_transcript(
      id: record.id, claim_id: "some-other-claim", text: "resultado tardío", provider: "openai"
    )

    record.reload
    assert_equal "transcribing", record.status
    assert_nil record.transcript_raw
  end

  # The specific scenario fixed rule 13 names: the provider answers after the
  # certifier already confirmed, and must not touch their text.
  test "a result arriving after confirmation is refused and leaves transcript_edited intact" do
    record = dictation
    claim  = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")
    VoiceDictation.record_transcript(id: record.id, claim_id: claim, text: "cruda", provider: "openai")
    record.reload.update!(transcript_edited: "corregida por el certificador")
    assert VoiceDictation.claim_confirmation!(id: record.id, text: record.reload.confirmed_text)

    assert_not VoiceDictation.record_transcript(
      id: record.id, claim_id: claim, text: "resultado tardío del proveedor", provider: "openai"
    )

    record.reload
    assert_equal "confirmed", record.status
    assert_equal "corregida por el certificador", record.transcript_edited
    assert_equal "cruda", record.transcript_raw
  end

  test "a nil duration from the provider does not blank a duration measured at recording time" do
    record = dictation(duration_seconds: 137)
    claim  = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")

    VoiceDictation.record_transcript(
      id: record.id, claim_id: claim, text: "texto", provider: "openai", duration_seconds: nil
    )

    assert_equal 137, record.reload.duration_seconds
  end

  # --- T3, failure ---

  test "recording a failure under the live claim moves the dictation to failed" do
    record = dictation
    claim  = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")

    assert VoiceDictation.record_failure(id: record.id, claim_id: claim, reason: "ProviderError: 429")

    record.reload
    assert_equal "failed", record.status
    assert_equal "ProviderError: 429", record.failure_reason
  end

  test "a failure from a superseded attempt cannot knock a transcribed dictation back" do
    record = dictation
    stale  = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")
    record.update_columns(transcribing_since: 1.day.ago)
    live = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")
    VoiceDictation.record_transcript(id: record.id, claim_id: live, text: "buena", provider: "openai")

    assert_not VoiceDictation.record_failure(id: record.id, claim_id: stale, reason: "late boom")

    record.reload
    assert_equal "transcribed", record.status
    assert_equal "buena", record.transcript_raw
  end

  test "a long failure reason is truncated to fit the column" do
    record = dictation
    claim  = VoiceDictation.claim_for_transcription!(id: record.id, provider: "openai")

    VoiceDictation.record_failure(id: record.id, claim_id: claim, reason: "x" * 900)

    assert_equal 250, record.reload.failure_reason.length
  end

  # --- T4 / T5 / T6 guards ---

  test "confirmation transition only fires from transcribed" do
    %i[pending transcribing failed confirmed].each do |status|
      record = dictation(status: status)
      assert_not VoiceDictation.claim_confirmation!(id: record.id, text: "texto"),
                 "confirming from #{status} must be refused"
    end

    record = dictation(status: :transcribed, transcript_raw: "cruda")
    assert VoiceDictation.claim_confirmation!(id: record.id, text: "cruda")
    record.reload
    assert_equal "confirmed", record.status
    assert_not_nil record.confirmed_at
    assert_equal "cruda", record.transcript_edited
  end

  test "reopening a failed dictation is refused once its audio was purged" do
    purged = dictation(status: :failed, audio_purged_at: Time.current, s3_key_audio: nil)
    assert_not VoiceDictation.reopen_failed!(id: purged.id)
    assert_equal "failed", purged.reload.status

    recoverable = dictation(status: :failed)
    assert VoiceDictation.reopen_failed!(id: recoverable.id)
    assert_equal "pending", recoverable.reload.status
  end

  test "the audio purge transition refuses every non-terminal state" do
    VoiceDictation::IN_PROGRESS_STATUSES.each do |status|
      record = dictation(status: status)
      assert_not VoiceDictation.claim_audio_purge!(id: record.id),
                 "audio of a dictation in #{status} is unfinished work"
      assert record.reload.audio_available?
    end

    VoiceDictation::TERMINAL_STATUSES.each do |status|
      record = dictation(status: status)
      assert VoiceDictation.claim_audio_purge!(id: record.id)
      record.reload
      assert_nil record.s3_key_audio
      assert_not_nil record.audio_purged_at
    end
  end

  test "the audio purge transition is idempotent" do
    record = dictation(status: :confirmed)
    assert VoiceDictation.claim_audio_purge!(id: record.id)
    assert_not VoiceDictation.claim_audio_purge!(id: record.id)
  end

  # --- Fase 5: autosave (record_edit) and undo (T7) ---

  test "an edit is accepted only while the dictation is transcribed" do
    %i[pending transcribing failed confirmed].each do |status|
      record = dictation(status: status, transcript_raw: "cruda")
      assert_not VoiceDictation.record_edit(id: record.id, text: "corregida"),
                 "editing from #{status} must be refused"
      assert_nil record.reload.transcript_edited
    end

    record = dictation(status: :transcribed, transcript_raw: "cruda")
    assert VoiceDictation.record_edit(id: record.id, text: "corregida")
    record.reload
    assert_equal "corregida", record.transcript_edited
    assert_equal "cruda", record.transcript_raw, "the autosave must never touch the raw transcript"
    assert_equal "transcribed", record.status, "the autosave must never move the state"
  end

  test "an edit cannot overwrite the text a confirmation froze" do
    record = dictation(status: :transcribed, transcript_raw: "cruda")
    assert VoiceDictation.claim_confirmation!(id: record.id, text: "confirmada")

    assert_not VoiceDictation.record_edit(id: record.id, text: "tardía")
    assert_equal "confirmada", record.reload.transcript_edited
  end

  test "undoing a confirmation returns the dictation to transcribed with its text intact" do
    record = dictation(status: :transcribed, transcript_raw: "cruda")
    VoiceDictation.claim_confirmation!(id: record.id, text: "corregida")

    assert VoiceDictation.reopen_confirmed!(id: record.id)
    record.reload
    assert_equal "transcribed", record.status
    assert_nil record.confirmed_at
    assert_equal "corregida", record.transcript_edited, "undo must never cost the certifier a correction"
    assert record.audio_available?
  end

  test "undo fires only from confirmed, and only once" do
    %i[pending transcribing transcribed failed].each do |status|
      record = dictation(status: status)
      assert_not VoiceDictation.reopen_confirmed!(id: record.id), "undo from #{status} must be refused"
      assert_equal status.to_s, record.reload.status
    end

    record = dictation(status: :confirmed)
    assert VoiceDictation.reopen_confirmed!(id: record.id)
    assert_not VoiceDictation.reopen_confirmed!(id: record.id)
  end

  test "awaiting_certifier lists every dictation the certifier still has to resolve, oldest first" do
    older  = dictation(status: :failed, created_at: 2.hours.ago)
    newer  = dictation(status: :transcribed, created_at: 1.hour.ago)
    queued = dictation(status: :pending)
    done   = dictation(status: :confirmed)

    ids = @report.voice_dictations.awaiting_certifier.pluck(:id)

    assert_includes ids, older.id, "a failed dictation still needs a human decision: retry or discard"
    assert_includes ids, newer.id
    assert_includes ids, queued.id
    assert_not_includes ids, done.id
    assert ids.index(older.id) < ids.index(newer.id)
  end

  # --- tenancy and integrity ---

  test "account_id is inherited from the report and cannot diverge from it" do
    record = VoiceDictation.create!(
      user: @user, certification_report: @report, sha256: SecureRandom.hex(32),
      content_type: "audio/webm"
    )
    assert_equal @report.account_id, record.account_id

    divergent = VoiceDictation.new(
      account: accounts(:climb), user: @user, certification_report: @report,
      sha256: SecureRandom.hex(32), content_type: "audio/webm"
    )
    assert_not divergent.valid?
    assert_includes divergent.errors[:account_id].to_s, "must match"
  end

  test "user_id is enforced by the database, not only by belongs_to" do
    assert_raises ActiveRecord::NotNullViolation do
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        INSERT INTO voice_dictations (account_id, sha256, content_type, status, created_at, updated_at)
        VALUES (#{@account.id}, '#{'c' * 64}', 'audio/webm', 'pending', NOW(), NOW())
      SQL
    end
  end

  test "owned_by isolates on both axes" do
    mine = dictation
    other_user = User.create!(email: "vd-#{SecureRandom.hex(4)}@example.com",
                              password: "password123", account: @account)
    theirs = dictation(report: nil, user: other_user, account: @account)

    scope = VoiceDictation.owned_by(account_id: @account.id, user_id: @user.id)
    assert_includes scope, mine
    assert_not_includes scope, theirs, "another user of the same account is not the owner"
    assert_not_includes VoiceDictation.owned_by(account_id: accounts(:climb).id, user_id: @user.id), mine
  end

  # --- deduplication (section 2.2, gap 5) ---

  test "the same audio twice on the same report is refused by the unique index" do
    sha = SecureRandom.hex(32)
    dictation(sha: sha)

    assert_raises ActiveRecord::RecordNotUnique do
      VoiceDictation.create!(account: @account, user: @user, certification_report: @report,
                             sha256: sha, content_type: "audio/webm")
    end
  end

  test "the same audio on a different report is a legitimate second row" do
    sha   = SecureRandom.hex(32)
    other = CertificationReport.create!(account: @account, user: @user, building_name: "Otro edificio")

    first  = dictation(sha: sha)
    second = dictation(sha: sha, report: other)

    assert_not_equal first.id, second.id
    assert_equal 2, VoiceDictation.where(sha256: sha).count
  end

  # NULLS NOT DISTINCT: with the default NULL handling every report-less row
  # would be unique and a double tap would bill twice.
  test "two report-less dictations of the same audio still collide" do
    sha = SecureRandom.hex(32)
    dictation(sha: sha, report: nil)

    assert_raises ActiveRecord::RecordNotUnique do
      VoiceDictation.create!(account: @account, user: @user, certification_report: nil,
                             sha256: sha, content_type: "audio/webm")
    end
  end

  # --- lifecycle ---

  test "a dictation refuses to be destroyed while a finding still points at it" do
    record  = dictation(status: :transcribed, transcript_raw: "texto")
    InspectionFinding.create!(certification_report: @report, body: "texto", voice_dictation: record)

    assert_not record.destroy
    assert VoiceDictation.exists?(record.id)
  end

  test "destroying a report destroys its dictations and deletes their audio bytes" do
    report = CertificationReport.create!(account: @account, user: @user, building_name: "Para borrar")
    record = dictation(status: :transcribed, report: report, transcript_raw: "texto")
    InspectionFinding.create!(certification_report: report, body: "texto", voice_dictation: record)

    fake = FakeS3.new
    with_fake_s3(fake) { assert report.destroy }

    assert_not VoiceDictation.exists?(record.id)
    assert_equal [ VoiceDictationAudio.prefix_for(account_id: @account.id, sha256: record.sha256) ],
                 fake.prefixes, "deleting a draft must not leave paid-for audio in the bucket"
  end

  test "an account with dictations cannot be destroyed" do
    account = Account.create!(slug: "vd-#{SecureRandom.hex(4)}", display_name: "Con dictados")
    user    = User.create!(email: "vd-#{SecureRandom.hex(4)}@example.com",
                           password: "password123", account: account)
    VoiceDictation.create!(account: account, user: user, sha256: SecureRandom.hex(32),
                           content_type: "audio/webm")

    assert_not account.destroy
    # The error lands on :base, same as the reports guard in
    # certification_report_test.rb; asserting on its text would be asserting on
    # a locale string this app does not define for restrict_dependent_destroy.
    assert account.errors[:base].any?
    assert VoiceDictation.exists?(account_id: account.id)
  end

  # --- derived values ---

  test "confirmed_text prefers the certifier's correction over the raw transcript" do
    assert_equal "cruda", dictation(transcript_raw: "cruda").confirmed_text
    assert_equal "corregida",
                 dictation(transcript_raw: "cruda", transcript_edited: "corregida").confirmed_text
  end

  test "audio_available? is false once the bytes are gone" do
    assert dictation.audio_available?
    assert_not dictation(s3_key_audio: nil).audio_available?
    assert_not dictation(audio_purged_at: Time.current).audio_available?
  end

  # Fase 6 reads this instead of bedrock_queries, which never sees a
  # transcription (fixed rule 7).
  test "cost_by_provider rolls up spend without touching bedrock_queries" do
    account = Account.create!(slug: "vd-#{SecureRandom.hex(4)}", display_name: "Costos")
    user    = User.create!(email: "vd-#{SecureRandom.hex(4)}@example.com",
                           password: "password123", account: account)
    own = { report: nil, account: account, user: user, status: :confirmed }

    assert_no_difference -> { BedrockQuery.count } do
      dictation(**own, provider: "amazon_transcribe", duration_seconds: 60, cost_estimate_usd: 0.024)
      dictation(**own, provider: "amazon_transcribe", duration_seconds: 120, cost_estimate_usd: 0.048)
      dictation(**own, provider: "groq", duration_seconds: 60, cost_estimate_usd: 0.0007)
    end

    rollup = VoiceDictation.cost_by_provider(since: 1.hour.ago, account_id: account.id)

    assert_equal %w[amazon_transcribe groq], rollup.keys.sort,
                 "the rollup must not pick up another tenant's spend"
    assert_equal 180, rollup["amazon_transcribe"][:seconds]
    assert_equal 0.072, rollup["amazon_transcribe"][:cost_usd]
    assert_equal 1, rollup["groq"][:dictations]
  end

  test "Danebo never fills the certifier's classification fields on a dictated finding" do
    record  = dictation(status: :transcribed, transcript_raw: "Puerta con holgura.")
    finding = VoiceDictationConfirmation.call(record)

    assert_nil finding.severity
    assert_nil finding.nch2840_box
    assert_nil finding.norm_point
    assert_nil finding.inspection_item
  end
end
