# frozen_string_literal: true

# Append-only dialogue and turn trace. conversation_history is the live
# workspace and isolate_web_trial replaces it. This table is the copy the
# export reads after that replacement. No foreign keys: a deleted user does
# not erase the audit row.
class CreateFieldCompanionTraces < ActiveRecord::Migration[8.1]
  def change
    create_table :field_companion_traces do |t|
      t.bigint :account_id, null: false
      t.bigint :user_id
      t.bigint :conversation_session_id
      t.string :episode_id
      t.string :correlation_id
      t.string :request_id
      t.string :job_id
      t.integer :attempt
      t.string :kind, null: false
      t.string :provenance, null: false, default: "observed"
      t.string :idempotency_key, null: false
      t.string :content_sha256
      t.string :deployed_version
      t.datetime :occurred_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end

    add_index :field_companion_traces, :idempotency_key, unique: true
    add_index :field_companion_traces, [ :account_id, :occurred_at ]
    add_index :field_companion_traces, :correlation_id
    add_index :field_companion_traces, [ :conversation_session_id, :occurred_at ],
      name: "idx_field_companion_traces_on_session_and_occurred_at"
  end
end
