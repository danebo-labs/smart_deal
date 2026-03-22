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

ActiveRecord::Schema[8.1].define(version: 2026_03_21_133924) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "bedrock_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "input_tokens"
    t.integer "latency_ms"
    t.string "model_id"
    t.integer "output_tokens"
    t.datetime "updated_at", null: false
    t.text "user_query"
  end

  create_table "conversation_sessions", force: :cascade do |t|
    t.jsonb "active_entities", default: {}, null: false
    t.string "channel", default: "whatsapp", null: false
    t.jsonb "conversation_history", default: [], null: false
    t.datetime "created_at", null: false
    t.jsonb "current_procedure", default: {}, null: false
    t.datetime "expires_at", null: false
    t.string "identifier", null: false
    t.string "session_status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index [ "active_entities" ], name: "index_conversation_sessions_on_active_entities", using: :gin
    t.index [ "conversation_history" ], name: "index_conversation_sessions_on_conversation_history", using: :gin
    t.index [ "expires_at" ], name: "index_conversation_sessions_on_expires_at"
    t.index [ "identifier", "channel" ], name: "index_conversation_sessions_on_identifier_and_channel", unique: true
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

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index [ "email" ], name: "index_users_on_email", unique: true
    t.index [ "reset_password_token" ], name: "index_users_on_reset_password_token", unique: true
  end
end
