# frozen_string_literal: true

# Carries a dictation's progress back to the certifier who recorded it.
#
# The stream is keyed by user, not by account: KbSyncChannel's
# "account:<id>:kb_sync" reaches every user of the account, which is the wrong
# blast radius for one certifier's inspection notes (fixed rule 12).
class VoiceDictationChannel < ApplicationCable::Channel
  def subscribed
    stream_from VoiceDictationBroadcaster.channel_for(current_user.id)
  end

  def unsubscribed
    stop_all_streams
  end
end
