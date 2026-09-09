# frozen_string_literal: true

# One dictation: the audio a certifier recorded, its transcription, and the
# cost of producing it. This is the phase's own telemetry table — transcriptions
# never create bedrock_queries rows, whose `source` enum is closed and whose
# every row assumes input_tokens > 0 (fixed rule 7).
#
# The state machine (pending → transcribing → transcribed | failed;
# transcribed → confirmed) is driven entirely by conditional updates on these
# columns; see the Diseño block of Fase 4 in
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md for the transition table.
#
# `transcription_claim_id` is what makes "one dictation = one billed call"
# checkable: the claim writes a fresh UUID and only a result carrying that same
# UUID may write a transcript, so a result arriving after a confirmation or
# after a stale re-claim updates zero rows instead of overwriting an edit.
class CreateVoiceDictations < ActiveRecord::Migration[8.1]
  def change
    create_table :voice_dictations do |t|
      t.references :account, null: false, foreign_key: true
      # bigint without a foreign key, the pattern already used by
      # conversation_sessions / field_photos / pilot_events; presence is
      # guaranteed by belongs_to :user.
      t.bigint :user_id, null: false
      # Nullable: a dictation can be recorded before the certifier picks the
      # report it belongs to. Index omitted here — the composite one below
      # leads with certification_report_id.
      t.references :certification_report, foreign_key: true, index: false

      # Cleared (not the row) when the retention job purges the audio, so the
      # cost telemetry and the finding's traceability link both survive.
      t.string :s3_key_audio
      t.string :sha256, null: false
      t.string :content_type, null: false
      t.integer :byte_size
      t.integer :duration_seconds

      t.string :provider
      t.string :status, null: false, default: "pending"
      t.text   :transcript_raw
      # Written only by the certifier's autosave (Fase 5) and frozen on
      # confirmation. No job transition ever writes this column.
      t.text   :transcript_edited
      t.datetime :confirmed_at
      t.decimal  :cost_estimate_usd, precision: 10, scale: 6

      t.string   :transcription_claim_id
      t.datetime :transcribing_since
      t.datetime :audio_purged_at
      t.string   :failure_reason

      t.timestamps
    end

    add_index :voice_dictations, :user_id

    # Deduplication is per report, not global: a double tap on the same report
    # returns the same row, while the same audio filed against another report is
    # a legitimate new row (section 2.2, gap 5). NULLS NOT DISTINCT (PostgreSQL
    # 15+) is what makes a report-less dictation dedup too — with the default
    # NULL handling every report-less row would be unique and a double tap
    # would bill twice.
    add_index :voice_dictations,
              [ :account_id, :certification_report_id, :sha256 ],
              unique: true, nulls_not_distinct: true,
              name: "idx_voice_dictations_account_report_sha"

    # "Reopening a report shows the dictations still in flight" (Fase 5).
    add_index :voice_dictations,
              [ :certification_report_id, :status ],
              name: "idx_voice_dictations_report_status"

    # The retention job's daily sweep: terminal states past the window.
    add_index :voice_dictations,
              [ :status, :created_at ],
              name: "idx_voice_dictations_status_created"
  end
end
