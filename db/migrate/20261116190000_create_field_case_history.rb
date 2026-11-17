# frozen_string_literal: true

# Durable field-case history. Additive. A personal workspace uses these
# tables without FIELD_CASE_HISTORY_ENABLED. A shared session does not.
# field_cases keeps the technical state. field_turns keeps each submission
# and its one definitive result. ConversationSession stays the live workspace.
# Traces stay the audit log. No foreign key to conversation_sessions: a case
# outlives session expiry and recreation.
class CreateFieldCaseHistory < ActiveRecord::Migration[8.1]
  def change
    create_table :field_cases do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :creation_key
      t.string :episode_id, null: false
      t.string :mode, null: false, default: "resumable"
      t.string :title, limit: 300
      t.datetime :opened_at, null: false
      t.datetime :last_activity_at, null: false
      t.integer :schema_version, null: false, default: 1
      t.integer :state_revision, null: false, default: 0
      t.integer :last_sequence, null: false, default: 0
      t.jsonb :technical_state, null: false, default: {}
      t.jsonb :document_focus, null: false, default: []
      t.timestamps
    end

    add_index :field_cases, [ :account_id, :user_id, :episode_id ],
      unique: true, name: "idx_field_cases_episode"
    add_index :field_cases, [ :account_id, :user_id, :last_activity_at, :id ],
      order: { last_activity_at: :desc, id: :desc },
      name: "idx_field_cases_list"
    add_index :field_cases, [ :account_id, :user_id, :creation_key ],
      unique: true, where: "creation_key IS NOT NULL",
      name: "idx_field_cases_creation_key"

    add_check_constraint :field_cases, "state_revision >= 0", name: "chk_field_cases_state_revision"
    add_check_constraint :field_cases, "last_sequence >= 0", name: "chk_field_cases_last_sequence"
    add_check_constraint :field_cases, "schema_version >= 1", name: "chk_field_cases_schema_version"
    add_check_constraint :field_cases, "mode IN ('resumable', 'read_only')", name: "chk_field_cases_mode"
    add_check_constraint :field_cases, "episode_id ~ '^ep_[0-9a-f]{16}$'", name: "chk_field_cases_episode_id"
    add_check_constraint :field_cases,
      "creation_key IS NULL OR creation_key ~ '^[A-Za-z0-9_-]{1,64}$'",
      name: "chk_field_cases_creation_key"
    add_check_constraint :field_cases, "jsonb_typeof(technical_state) = 'object'", name: "chk_field_cases_state_object"
    add_check_constraint :field_cases, "jsonb_typeof(document_focus) = 'array'", name: "chk_field_cases_focus_array"

    create_table :field_turns do |t|
      t.references :field_case, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.integer :sequence, null: false
      t.string :client_submission_id, null: false
      t.string :input_digest, null: false
      t.string :correlation_id, null: false
      t.string :kind, null: false
      t.text :message, null: false, default: ""
      t.references :field_photo, foreign_key: { on_delete: :nullify }, index: true
      t.jsonb :attachment, null: false, default: {}
      t.string :locale
      t.string :status, null: false
      t.string :phase, null: false
      t.integer :attempt, null: false, default: 1
      t.string :execution_token, null: false
      t.datetime :lease_expires_at
      t.integer :base_state_revision, null: false
      t.integer :result_state_revision
      t.jsonb :response
      t.text :prompt_reply
      t.jsonb :checkpoint
      t.string :failure_stage
      t.string :failure_code
      t.datetime :admitted_at, null: false
      t.datetime :completed_at
      t.timestamps
    end

    add_index :field_turns, [ :field_case_id, :sequence ],
      unique: true, name: "idx_field_turns_case_sequence"
    add_index :field_turns, [ :field_case_id, :client_submission_id ],
      unique: true, name: "idx_field_turns_case_submission"
    add_index :field_turns, :correlation_id, unique: true, name: "idx_field_turns_correlation"
    add_index :field_turns, :field_case_id,
      unique: true, where: "status = 'pending'", name: "idx_field_turns_one_pending"
    add_index :field_turns, :lease_expires_at,
      where: "status = 'pending'", name: "idx_field_turns_pending_lease"

    add_check_constraint :field_turns, "sequence > 0", name: "chk_field_turns_sequence"
    add_check_constraint :field_turns, "attempt > 0", name: "chk_field_turns_attempt"
    add_check_constraint :field_turns, "base_state_revision >= 0", name: "chk_field_turns_base_revision"
    add_check_constraint :field_turns,
      "result_state_revision IS NULL OR result_state_revision > base_state_revision",
      name: "chk_field_turns_result_revision"
    add_check_constraint :field_turns,
      "status IN ('pending', 'completed', 'failed', 'historical_partial')",
      name: "chk_field_turns_status"
    add_check_constraint :field_turns, "kind IN ('text', 'photo')", name: "chk_field_turns_kind"
    add_check_constraint :field_turns,
      "phase IN ('queued', 'interpreting', 'vision', 'technical', 'published', 'failed', 'imported')",
      name: "chk_field_turns_phase"
    add_check_constraint :field_turns, "char_length(message) <= 8000", name: "chk_field_turns_message_cap"
    add_check_constraint :field_turns, "jsonb_typeof(attachment) = 'object'", name: "chk_field_turns_attachment"
    add_check_constraint :field_turns,
      "client_submission_id ~ '^[A-Za-z0-9_-]{1,64}$'",
      name: "chk_field_turns_submission_id"
    add_check_constraint :field_turns, "input_digest ~ '^[0-9a-f]{64}$'", name: "chk_field_turns_digest"
    add_check_constraint :field_turns,
      "correlation_id ~ '^(query|photo):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'",
      name: "chk_field_turns_correlation"
    add_check_constraint :field_turns,
      "execution_token ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'",
      name: "chk_field_turns_token"
    add_check_constraint :field_turns,
      "failure_code IS NULL OR failure_code ~ '^[a-z][a-z0-9_]{0,39}$'",
      name: "chk_field_turns_failure_code"
    add_check_constraint :field_turns,
      "failure_stage IS NULL OR failure_stage ~ '^[a-z][a-z0-9_]{0,39}$'",
      name: "chk_field_turns_failure_stage"
    add_check_constraint :field_turns, "locale IS NULL OR char_length(locale) <= 16", name: "chk_field_turns_locale"
    add_check_constraint :field_turns,
      "prompt_reply IS NULL OR char_length(prompt_reply) <= 16000",
      name: "chk_field_turns_prompt_reply"
    add_check_constraint :field_turns,
      "response IS NULL OR jsonb_typeof(response) = 'object'",
      name: "chk_field_turns_response_object"
    add_check_constraint :field_turns,
      "checkpoint IS NULL OR jsonb_typeof(checkpoint) = 'object'",
      name: "chk_field_turns_checkpoint"
    add_check_constraint :field_turns,
      "status <> 'pending' OR (response IS NULL AND completed_at IS NULL AND failure_code IS NULL)",
      name: "chk_field_turns_pending_open"
    add_check_constraint :field_turns,
      "status = 'pending' OR completed_at IS NOT NULL",
      name: "chk_field_turns_terminal_time"
    add_check_constraint :field_turns,
      "status <> 'completed' OR (response IS NOT NULL AND COALESCE(char_length(response->>'published_text'), 0) > 0)",
      name: "chk_field_turns_completed_response"
    add_check_constraint :field_turns,
      "status <> 'failed' OR failure_code IS NOT NULL",
      name: "chk_field_turns_failed_code"
  end
end
