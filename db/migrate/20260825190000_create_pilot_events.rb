# frozen_string_literal: true

# Durable copy of [PILOT_USAGE] and [RAG_QUALITY] so a Docker log rotation
# cannot erase a pilot day again (2026-08-10). No FKs: same attribution
# pattern as bedrock_queries. occurred_at is the event's own ts, not the
# INSERT time. Raw question/answer text never belongs in payload — that
# stays under PILOT_AUDIT_CAPTURE in logs and Frente A (S3).
class CreatePilotEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :pilot_events do |t|
      t.string :event, null: false
      t.string :correlation_id
      t.bigint :account_id
      t.bigint :user_id
      t.bigint :conversation_session_id
      t.datetime :occurred_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end

    add_index :pilot_events, :occurred_at
    add_index :pilot_events, :correlation_id
    add_index :pilot_events, [ :event, :occurred_at ]
  end
end
