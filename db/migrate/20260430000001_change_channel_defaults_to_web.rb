# frozen_string_literal: true

# WA channel disabled for MVP: flip default channel from "whatsapp" to "web"
# on both tables so new rows are created as web sessions by default.
# Existing rows are NOT backfilled (legacy WA rows remain valid; CHANNELS still
# includes "whatsapp" for backward compatibility).
class ChangeChannelDefaultsToWeb < ActiveRecord::Migration[8.1]
  def up
    change_column_default :conversation_sessions,  :channel, from: "whatsapp", to: "web"
    change_column_default :technician_documents,   :channel, from: "whatsapp", to: "web"
  end

  def down
    change_column_default :conversation_sessions,  :channel, from: "web", to: "whatsapp"
    change_column_default :technician_documents,   :channel, from: "web", to: "whatsapp"
  end
end
