# frozen_string_literal: true

# The explicit human retry of a failed dictation (T5 of the Fase 4 state
# machine), wired to the job that will bill for it.
#
# This is the one place in the certifier UI that deliberately spends a second
# provider call, so it sits behind a tap — never a timer, never an automatic
# retry (fixed rule 13). The reopen is a conditional UPDATE, so two taps on the
# same failed dictation reopen it once and enqueue once; the loser sees false
# and enqueues nothing.
class VoiceDictationRetry
  # @return [Boolean] true when the dictation was reopened and a transcription
  #   enqueued; false when it wasn't `failed` or its audio is already purged
  #   (nothing left to send — the UI offers re-recording instead).
  def self.call(dictation)
    return false unless VoiceDictation.reopen_failed!(id: dictation.id)

    TranscriptionJob.perform_later(voice_dictation_id: dictation.id)
    true
  end
end
