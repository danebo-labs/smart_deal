# frozen_string_literal: true

# One dictation of a certifier: the recorded audio, the transcript produced from
# it, and what that transcript cost to produce (Fase 4 of
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md).
#
# Every state change is a single conditional UPDATE and the caller decides on
# the number of rows affected — never `dictation.status = ...; save`. That is
# what turns fixed rule 13 ("one dictation = one billed call = one finding")
# into something the database enforces rather than something the code intends:
#
#   pending ──claim──▶ transcribing ──result──▶ transcribed ──confirm──▶ confirmed
#                            │                      ▲    ▲                 │
#                            └──error──▶ failed ────┘    └────── undo ─────┘ (T7, Fase 5)
#                                              (explicit human retry)
#
# `transcript_edited` is written by exactly two places, and neither is a job:
# the certifier's autosave (Fase 5, .record_edit) and the freeze performed on
# confirmation. A transcript arriving late from a provider can therefore never
# overwrite an edit — see #claim_for_transcription! and .record_transcript.
#
# Audio retention (fixed rule 10): the purge clears `s3_key_audio` and stamps
# `audio_purged_at`, keeping the row. Destroying it would take the finding's
# traceability link and this phase's cost telemetry with it.
class VoiceDictation < ApplicationRecord
  STATUSES = {
    pending:      "pending",
    transcribing: "transcribing",
    transcribed:  "transcribed",
    failed:       "failed",
    confirmed:    "confirmed"
  }.freeze

  # Audio of a terminal dictation is purgeable; audio of anything else is work
  # in progress and is never touched, because "close and reopen without losing
  # audio" is fixed rule 11.
  TERMINAL_STATUSES   = [ STATUSES[:confirmed], STATUSES[:failed] ].freeze
  IN_PROGRESS_STATUSES = (STATUSES.values - TERMINAL_STATUSES).freeze

  # A worker killed mid-provider-call (deploy, SIGKILL) would otherwise strand
  # the audio in `transcribing` forever. Re-claiming after this window costs one
  # extra billed call, which is the deliberate price of recoverability; it is
  # long enough that it can never race a live call.
  DEFAULT_STALE_CLAIM_MINUTES = 30

  belongs_to :account
  belongs_to :user
  belongs_to :certification_report, optional: true

  # Restrictive on purpose: destroying a confirmed dictation would leave its
  # finding with no traceable origin. A report being destroyed still works —
  # CertificationReport declares its findings before its dictations, so the
  # findings are gone by the time the dictations are destroyed.
  has_one :inspection_finding, dependent: :restrict_with_error, inverse_of: :voice_dictation

  enum :status, STATUSES, default: :pending

  before_validation :inherit_account_from_report
  after_destroy :delete_audio_bytes

  validates :sha256, :content_type, presence: true
  validate :account_matches_report

  scope :owned_by, ->(account_id:, user_id:) { where(account_id: account_id, user_id: user_id) }
  scope :recent_first, -> { order(created_at: :desc) }
  # What Fase 5 shows when a report is reopened: everything not yet resolved.
  scope :in_progress, -> { where(status: IN_PROGRESS_STATUSES) }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  # Everything the certifier still has a decision to make on when a report is
  # reopened: the in-progress states plus `failed`, which is terminal for the
  # purge but not for the human — retrying (T5) or discarding it is theirs.
  scope :awaiting_certifier, -> { where.not(status: STATUSES[:confirmed]).order(:created_at, :id) }
  scope :with_audio, -> { where(audio_purged_at: nil).where.not(s3_key_audio: nil) }

  class << self
    # T1 — the claim. A single UPDATE decides who is allowed to call the
    # provider: the caller that gets 1 row proceeds, everyone else gets nil and
    # must return without spending anything. The second branch of the WHERE is
    # the stale re-claim described in DEFAULT_STALE_CLAIM_MINUTES.
    #
    # @return [String, nil] the claim id to pass back to .record_transcript /
    #   .record_failure, or nil when another perform already holds the claim.
    def claim_for_transcription!(id:, provider:, claim_id: SecureRandom.uuid, now: Time.current)
      claimed = where(id: id)
                  .where(
                    "status = :pending OR (status = :transcribing AND transcribing_since < :stale_cutoff)",
                    pending: STATUSES[:pending],
                    transcribing: STATUSES[:transcribing],
                    stale_cutoff: now - stale_claim_minutes.minutes
                  )
                  .update_all(
                    status: STATUSES[:transcribing],
                    provider: provider,
                    transcribing_since: now,
                    transcription_claim_id: claim_id,
                    failure_reason: nil,
                    updated_at: now
                  )

      claimed == 1 ? claim_id : nil
    end

    # T2 — the result. Guarded by the claim id, not just by the status, so a
    # transcript whose claim is no longer the live one (the dictation was
    # confirmed meanwhile, or a stale re-claim superseded it) writes nothing.
    #
    # @return [Boolean] false when the result arrived too late and was dropped.
    def record_transcript(id:, claim_id:, text:, provider:, duration_seconds: nil,
                          cost_estimate_usd: nil, now: Time.current)
      attributes = {
        status: STATUSES[:transcribed],
        transcript_raw: text,
        provider: provider,
        failure_reason: nil,
        updated_at: now
      }
      # Never blank out a duration the client already measured with a nil the
      # provider happened not to report.
      attributes[:duration_seconds] = duration_seconds if duration_seconds.present?
      attributes[:cost_estimate_usd] = cost_estimate_usd if cost_estimate_usd.present?

      live_claim(id, claim_id).update_all(attributes) == 1
    end

    # T3 — the provider failed. Same claim guard: a failure from a superseded
    # attempt must not knock a healthy dictation out of `transcribed`.
    def record_failure(id:, claim_id:, reason:, now: Time.current)
      live_claim(id, claim_id).update_all(
        status: STATUSES[:failed],
        failure_reason: reason.to_s.first(250),
        updated_at: now
      ) == 1
    end

    # T4 — confirmation, the compare-and-set half of it. Taking the row lock
    # here is what serialises a double tap: the second caller blocks until the
    # first commits, then gets 0 and reads the finding the first one created.
    # VoiceDictationConfirmation owns the finding creation that goes with it.
    #
    # @return [Boolean] true for the single caller that won the transition.
    def claim_confirmation!(id:, text:, now: Time.current)
      where(id: id, status: STATUSES[:transcribed]).update_all(
        status: STATUSES[:confirmed],
        confirmed_at: now,
        transcript_edited: text,
        updated_at: now
      ) == 1
    end

    # The certifier's autosave (Fase 5). Only a `transcribed` dictation accepts
    # an edit: before that there is no text to correct, and after confirmation
    # the text is frozen as what went into the finding. Touches nothing but
    # transcript_edited — never transcript_raw, never status — so a late
    # provider result and a human correction can never race on the same
    # column (fixed rule 13).
    #
    # @return [Boolean] false when the dictation is not editable right now.
    def record_edit(id:, text:, now: Time.current)
      where(id: id, status: STATUSES[:transcribed]).update_all(
        transcript_edited: text,
        updated_at: now
      ) == 1
    end

    # T5 — an explicit human retry of a failed dictation, which costs one new
    # billed call. Refused once the audio is gone: there would be nothing to
    # send.
    def reopen_failed!(id:, now: Time.current)
      where(id: id, status: STATUSES[:failed], audio_purged_at: nil).update_all(
        status: STATUSES[:pending],
        failure_reason: nil,
        transcription_claim_id: nil,
        transcribing_since: nil,
        updated_at: now
      ) == 1
    end

    # T7 — the inline undo of a confirmation (Fase 5, Salesforce Voice-to-Form
    # pattern). Puts the dictation back in front of the certifier, text intact:
    # transcript_edited is deliberately *not* cleared, so undoing a premature
    # tap never costs a correction, and never a re-recording. The finding the
    # confirmation created is destroyed by VoiceDictationConfirmation.undo in
    # the same transaction; this is only the state half. No provider call is
    # involved, so it costs nothing.
    #
    # @return [Boolean] true for the single caller that reopened it.
    def reopen_confirmed!(id:, now: Time.current)
      where(id: id, status: STATUSES[:confirmed]).update_all(
        status: STATUSES[:transcribed],
        confirmed_at: nil,
        updated_at: now
      ) == 1
    end

    # T6 — the second layer of the audio retention policy. The retention job's
    # batch query already excludes non-terminal dictations; this re-checks
    # terminality per row, so a dictation that left a terminal state after the
    # batch was loaded loses the race here, with its audio still in the bucket.
    #
    # @return [Boolean] false means the row was not purgeable after all, and the
    #   caller must not delete anything from S3.
    def claim_audio_purge!(id:, now: Time.current)
      where(id: id, status: TERMINAL_STATUSES, audio_purged_at: nil).update_all(
        s3_key_audio: nil,
        audio_purged_at: now,
        updated_at: now
      ) == 1
    end

    def stale_claim_minutes
      ENV.fetch("STT_STALE_CLAIM_MINUTES", DEFAULT_STALE_CLAIM_MINUTES).to_i
    end

    # This phase's own cost telemetry (fixed rule 7): voice spend is duration
    # times a published rate, never a bedrock_queries row. Direct input for the
    # COGS table of Fase 6.
    #
    # `account_id` is optional because Fase 6 measures global COGS, but voice
    # spend is per-tenant the moment there is more than one pilot — the seam is
    # here rather than at the call sites.
    def cost_by_provider(since: 30.days.ago, account_id: nil)
      scope = where(created_at: since..).where.not(provider: nil)
      scope = scope.where(account_id: account_id) if account_id.present?

      scope.group(:provider)
        .pluck(
          Arel.sql("provider"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(duration_seconds), 0)"),
          Arel.sql("COALESCE(SUM(cost_estimate_usd), 0)")
        )
        .to_h do |provider, count, seconds, cost|
          [ provider, { dictations: count, seconds: seconds.to_i, cost_usd: cost.to_f.round(6) } ]
        end
    end

    private

    def live_claim(id, claim_id)
      where(id: id, status: STATUSES[:transcribing], transcription_claim_id: claim_id)
    end
  end

  # What a confirmation commits: the certifier's correction when there is one,
  # the raw transcript otherwise. Never the audio (fixed rule 3).
  def confirmed_text
    transcript_edited.presence || transcript_raw
  end

  def audio_available?
    audio_purged_at.nil? && s3_key_audio.present?
  end

  private

  def inherit_account_from_report
    self.account_id ||= certification_report&.account_id
  end

  # Same guard InspectionFinding uses: a denormalized account_id that could
  # drift from its report would be worse than a join.
  def account_matches_report
    return if account_id.blank? || certification_report.nil?
    return if account_id == certification_report.account_id

    errors.add(:account_id, "must match the certification report's account")
  end

  # Deleting a draft report should actually free its audio, not leave paid-for
  # bytes in the bucket with no row pointing at them. Runs after the row is
  # gone, the same safe order the retention job uses.
  def delete_audio_bytes
    return unless audio_available?

    VoiceDictationAudio.delete!(account_id: account_id, sha256: sha256)
  end
end
