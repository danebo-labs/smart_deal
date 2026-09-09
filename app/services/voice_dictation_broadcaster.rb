# frozen_string_literal: true

# Delivers a dictation's outcome to the certifier who recorded it — and to
# nobody else.
#
# Explicitly *not* the KbSyncBroadcaster pattern. That one streams to
# "account:<id>:kb_sync", which every user of the account is subscribed to;
# reusing it here would put one certifier's dictation on their colleagues'
# screens. Isolation in this module is double: by account through the host, and
# by user through ownership (fixed rule 12, section 2.2 gap 4).
class VoiceDictationBroadcaster
  # Enough for the certifier to see their words appear; the full transcript
  # comes from the database when the editable panel loads. Caps what a growing
  # transcript can push through the cable.
  TRANSCRIPT_PREVIEW_LIMIT = 2_000

  class << self
    def channel_for(user_id)
      "user:#{user_id}:voice_dictations"
    end

    def transcribed(dictation)
      broadcast(
        dictation,
        status: "transcribed",
        transcript: dictation.transcript_raw.to_s.first(TRANSCRIPT_PREVIEW_LIMIT)
      )
    end

    def failed(dictation, reason:)
      broadcast(dictation, status: "failed", reason: reason.to_s.first(250))
    end

    private

    def broadcast(dictation, payload)
      ActionCable.server.broadcast(
        channel_for(dictation.user_id),
        {
          voice_dictation_id: dictation.id,
          certification_report_id: dictation.certification_report_id
        }.merge(payload)
      )
    end
  end
end
