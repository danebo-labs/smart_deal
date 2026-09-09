# frozen_string_literal: true

# Purges the audio of dictations that are done with, and only those.
#
# A dictation still `pending`, `transcribing` or `transcribed` is unfinished
# work: the certifier may be about to reopen the report and read the transcript
# they never confirmed, and "close and reopen without losing audio" is fixed
# rule 11. Only terminal dictations — confirmed, so the text is already in the
# report, or failed — are eligible (fixed rule 10).
#
# Two independent layers enforce that, which is the lesson of the Fase 0
# closing block: a test that only asserts "the unconfirmed dictation is still
# there" can pass with the exclusion deleted, because a second layer rescues
# it. Layer one is #purgeable, which never selects a non-terminal row. Layer
# two is VoiceDictation.claim_audio_purge!, which re-checks terminality inside
# the UPDATE and catches a dictation that left a terminal state after the batch
# was loaded (an explicit retry, T5). `aborted` counts layer two firing, so a
# healthy run proves the *query* protected the audio.
#
# The row survives: only s3_key_audio is cleared. Destroying it would take the
# finding's traceability link and this phase's cost telemetry with it. The safe
# ordering of Fase 0 is preserved in substance — the reversible database write
# happens before the irreversible S3 delete, so a failure leaves bytes in the
# bucket rather than a row pointing nowhere.
#
# Scheduled daily via config/recurring.yml.
class VoiceDictationRetentionJob < ApplicationJob
  queue_as :default

  DEFAULT_RETENTION_DAYS = 90

  # @return [Hash] { purged:, kept:, aborted: } — `kept` counts unfinished
  #   dictations past the window that the exclusion protected, `aborted` counts
  #   the per-row re-check firing. A healthy run has aborted == 0.
  def perform
    cutoff  = ENV.fetch("VOICE_DICTATION_RETENTION_DAYS", DEFAULT_RETENTION_DAYS).to_i.days.ago
    purged  = 0
    aborted = 0
    kept    = unfinished_past(cutoff).count

    purgeable(cutoff).in_batches do |batch|
      batch.each do |dictation|
        unless VoiceDictation.claim_audio_purge!(id: dictation.id)
          aborted += 1
          next
        end

        VoiceDictationAudio.delete!(account_id: dictation.account_id, sha256: dictation.sha256)
        purged += 1
      end
    end

    Rails.logger.info(
      "VoiceDictationRetentionJob: purged audio of #{purged} terminal dictation(s), " \
      "kept #{kept} still unconfirmed, #{aborted} aborted on the terminal-state re-check"
    )

    { purged: purged, kept: kept, aborted: aborted }
  end

  private

  def purgeable(cutoff)
    VoiceDictation.terminal.with_audio.where(created_at: ...cutoff)
  end

  def unfinished_past(cutoff)
    VoiceDictation.in_progress.with_audio.where(created_at: ...cutoff)
  end
end
