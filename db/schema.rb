# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_23_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "accounts", force: :cascade do |t|
    t.boolean "branded", default: false, null: false
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index [ "slug" ], name: "index_accounts_on_slug", unique: true
  end

  create_table "bedrock_daily_costs", force: :cascade do |t|
    t.bigint "cache_read_tokens", default: 0, null: false
    t.bigint "cache_write_tokens", default: 0, null: false
    t.decimal "cost_usd", precision: 20, scale: 6, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.bigint "input_tokens", default: 0, null: false
    t.integer "invocation_count", default: 0, null: false
    t.string "model_id", null: false
    t.bigint "output_tokens", default: 0, null: false
    t.datetime "reconciled_at", null: false
    t.datetime "updated_at", null: false
    t.date "utc_date", null: false
    t.index [ "utc_date", "model_id" ], name: "index_bedrock_daily_costs_on_utc_date_and_model_id", unique: true
    t.index [ "utc_date" ], name: "index_bedrock_daily_costs_on_utc_date"
  end

  create_table "bedrock_queries", force: :cascade do |t|
    t.bigint "account_id"
    t.integer "attempt"
    t.integer "cache_creation_tokens"
    t.integer "cache_read_tokens"
    t.bigint "conversation_session_id"
    t.string "correlation_id"
    t.datetime "created_at", null: false
    t.integer "input_tokens"
    t.integer "latency_ms"
    t.integer "max_tokens"
    t.string "model_id"
    t.integer "output_tokens"
    t.string "route"
    t.string "source", default: "query", null: false
    t.string "stop_reason"
    t.string "token_source"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.text "user_query"
    t.index [ "account_id", "user_id", "created_at" ], name: "index_bedrock_queries_on_account_id_and_user_id_and_created_at"
    t.index [ "correlation_id" ], name: "index_bedrock_queries_on_correlation_id"
    t.index [ "source", "created_at" ], name: "index_bedrock_queries_on_source_and_created_at"
  end

  create_table "bulk_upload_assets", force: :cascade do |t|
    t.jsonb "aliases", default: [], null: false
    t.jsonb "batch_custom_ids", default: [], null: false
    t.bigint "bulk_upload_id", null: false
    t.string "canonical_name"
    t.integer "chunks_count"
    t.string "chunks_s3_prefix"
    t.integer "claude_input_tokens"
    t.integer "claude_output_tokens"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "custom_id", null: false
    t.text "error_message"
    t.string "filename", null: false
    t.string "ingestion_contract_version"
    t.string "ingestion_path"
    t.bigint "kb_document_id"
    t.boolean "office_origin", default: false, null: false
    t.string "s3_key"
    t.string "sha256", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index [ "bulk_upload_id", "custom_id" ], name: "index_bulk_upload_assets_on_bulk_upload_id_and_custom_id"
    t.index [ "bulk_upload_id" ], name: "index_bulk_upload_assets_on_bulk_upload_id"
    t.index [ "custom_id" ], name: "index_bulk_upload_assets_on_custom_id", unique: true
    t.index [ "kb_document_id" ], name: "index_bulk_upload_assets_on_kb_document_id"
    t.index [ "status" ], name: "index_bulk_upload_assets_on_status"
  end

  create_table "bulk_uploads", force: :cascade do |t|
    t.integer "asset_count", default: 0, null: false
    t.string "bedrock_ingestion_job_id"
    t.string "claude_batch_id"
    t.jsonb "claude_batch_ids", default: [], null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "original_filename", null: false
    t.string "sha256", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index [ "sha256" ], name: "index_bulk_uploads_on_sha256", unique: true
    t.index [ "status" ], name: "index_bulk_uploads_on_status"
    t.index [ "user_id" ], name: "index_bulk_uploads_on_user_id"
  end

  create_table "conversation_sessions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.jsonb "active_entities", default: {}, null: false
    t.string "channel", default: "web", null: false
    t.jsonb "conversation_history", default: [], null: false
    t.datetime "created_at", null: false
    t.jsonb "current_procedure", default: {}, null: false
    t.datetime "expires_at", null: false
    t.string "identifier", null: false
    t.string "session_status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index [ "account_id", "identifier", "channel" ], name: "idx_conversation_sessions_account_id_channel", unique: true
    t.index [ "account_id" ], name: "index_conversation_sessions_on_account_id"
    t.index [ "active_entities" ], name: "index_conversation_sessions_on_active_entities", using: :gin
    t.index [ "conversation_history" ], name: "index_conversation_sessions_on_conversation_history", using: :gin
    t.index [ "expires_at" ], name: "index_conversation_sessions_on_expires_at"
    t.index [ "user_id" ], name: "index_conversation_sessions_on_user_id"
  end

  create_table "cost_metrics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.text "metadata", default: "{}"
    t.integer "metric_type", null: false
    t.datetime "updated_at", null: false
    t.decimal "value", precision: 20, scale: 6, null: false
    t.index [ "date", "metric_type" ], name: "index_cost_metrics_on_date_and_metric_type", unique: true
    t.index [ "date" ], name: "index_cost_metrics_on_date"
  end

  create_table "kb_document_thumbnails", force: :cascade do |t|
    t.integer "byte_size"
    t.string "content_type", default: "image/jpeg", null: false
    t.datetime "created_at", null: false
    t.binary "data", null: false
    t.integer "height"
    t.bigint "kb_document_id", null: false
    t.datetime "updated_at", null: false
    t.integer "width"
    t.index [ "kb_document_id" ], name: "index_kb_document_thumbnails_on_kb_document_id", unique: true
  end

  create_table "kb_documents", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.jsonb "aliases", default: [], null: false
    t.datetime "created_at", null: false
    t.string "display_name"
    t.uuid "document_uid", null: false
    t.string "s3_key", null: false
    t.bigint "size_bytes"
    t.datetime "updated_at", null: false
    t.index "lower((aliases)::text) gin_trgm_ops", name: "idx_kb_documents_aliases_text_trgm", using: :gin
    t.index "lower((display_name)::text) gin_trgm_ops", name: "idx_kb_documents_display_name_trgm", using: :gin
    t.index [ "account_id", "document_uid" ], name: "idx_kb_documents_account_document_uid", unique: true
    t.index [ "account_id", "s3_key" ], name: "idx_kb_documents_account_s3_key", unique: true
    t.index [ "account_id" ], name: "index_kb_documents_on_account_id"
  end

  create_table "technician_documents", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.jsonb "aliases", default: [], null: false
    t.string "canonical_name", null: false
    t.string "channel", default: "web", null: false
    t.datetime "created_at", null: false
    t.string "doc_type"
    t.string "first_answer_summary"
    t.string "identifier", null: false
    t.integer "interaction_count", default: 1, null: false
    t.datetime "last_used_at", null: false
    t.string "source_uri"
    t.datetime "updated_at", null: false
    t.string "wa_filename"
    t.index "account_id, lower((canonical_name)::text)", name: "idx_tech_docs_account_canonical_icase", unique: true
    t.index [ "last_used_at" ], name: "idx_tech_docs_recent_global"
    t.index [ "source_uri" ], name: "idx_tech_docs_source_uri", where: "((source_uri IS NOT NULL) AND ((source_uri)::text <> ''::text))"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index [ "account_id" ], name: "index_users_on_account_id"
    t.index [ "email" ], name: "index_users_on_email", unique: true
    t.index [ "reset_password_token" ], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "web_manual_batches", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.jsonb "aliases", default: [], null: false
    t.string "canonical_name"
    t.integer "chunks_count"
    t.string "chunks_s3_prefix"
    t.string "claude_batch_id"
    t.jsonb "claude_batch_ids", default: [], null: false
    t.datetime "completed_at"
    t.string "content_type", default: "application/pdf", null: false
    t.bigint "conv_session_id"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "filename", null: false
    t.string "ingestion_contract_version", null: false
    t.bigint "kb_document_id"
    t.jsonb "kept_pages", default: [], null: false
    t.string "locale"
    t.jsonb "page_customs", default: {}, null: false
    t.string "s3_key", null: false
    t.string "sha256", null: false
    t.string "status", default: "pending", null: false
    t.datetime "submitted_at"
    t.integer "total_pages"
    t.datetime "updated_at", null: false
    t.string "urgent_chunks_s3_prefix"
    t.datetime "urgent_completed_at"
    t.text "urgent_error_message"
    t.jsonb "urgent_pages", default: [], null: false
    t.datetime "urgent_started_at"
    t.string "urgent_status"
    t.index [ "account_id", "sha256", "s3_key", "ingestion_contract_version" ], name: "idx_web_manual_batches_account_contract", unique: true
    t.index [ "account_id" ], name: "index_web_manual_batches_on_account_id"
    t.index [ "claude_batch_id" ], name: "index_web_manual_batches_on_claude_batch_id", unique: true
    t.index [ "conv_session_id" ], name: "index_web_manual_batches_on_conv_session_id"
    t.index [ "kb_document_id" ], name: "index_web_manual_batches_on_kb_document_id"
    t.index [ "status" ], name: "index_web_manual_batches_on_status"
    t.index [ "urgent_status" ], name: "index_web_manual_batches_on_urgent_status"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'submitting'::character varying, 'submitted'::character varying, 'submission_unknown'::character varying, 'in_progress'::character varying, 'parsing'::character varying, 'parsed'::character varying, 'syncing'::character varying, 'complete'::character varying, 'failed'::character varying]::text[])", name: "chk_web_manual_batches_status"
  end

  create_table "whatsapp_cache_hits", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "recipient", null: false
    t.string "route", null: false
    t.integer "tokens_saved_estimate"
    t.datetime "updated_at", null: false
    t.index [ "recipient", "created_at" ], name: "index_whatsapp_cache_hits_on_recipient_and_created_at"
    t.index [ "route", "created_at" ], name: "index_whatsapp_cache_hits_on_route_and_created_at"
  end

  add_foreign_key "technician_documents", "accounts", name: "fk_td_account"
end
