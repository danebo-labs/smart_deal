# frozen_string_literal: true

# Broadcasts Knowledge Base ingestion job completion to connected clients.
# Clients subscribe to receive real-time updates when documents finish indexing.
class KbSyncChannel < ApplicationCable::Channel
  def subscribed
    stream_from "kb_sync"
  end

  def unsubscribed
    stop_all_streams
  end
end
