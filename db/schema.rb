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

ActiveRecord::Schema[8.0].define(version: 2026_07_20_063326) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "credit_transactions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "granted_by_id"
    t.string "kind", null: false
    t.integer "amount_cents", null: false
    t.string "note"
    t.string "model"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["granted_by_id"], name: "index_credit_transactions_on_granted_by_id"
    t.index ["kind"], name: "index_credit_transactions_on_kind"
    t.index ["user_id", "created_at"], name: "index_credit_transactions_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_credit_transactions_on_user_id"
  end

  create_table "llm_api_keys", force: :cascade do |t|
    t.bigint "user_id"
    t.text "llm_type"
    t.text "encrypted_api_key"
    t.text "uuid"
    t.timestamptz "created_at"
    t.timestamptz "updated_at"
    t.text "description"
    t.index ["user_id", "llm_type"], name: "idx_2679874_index_llm_api_keys_on_user_id_and_llm_type"
    t.index ["user_id"], name: "idx_2679874_index_llm_api_keys_on_user_id"
    t.index ["uuid"], name: "idx_2679874_index_llm_api_keys_on_uuid", unique: true
  end

  create_table "llm_models", force: :cascade do |t|
    t.bigint "llm_id"
    t.text "name"
    t.timestamptz "created_at"
    t.timestamptz "updated_at"
    t.text "display_name"
    t.text "api_id"
    t.index ["llm_id"], name: "idx_2679881_index_llm_models_on_llm_id"
  end

  create_table "llms", force: :cascade do |t|
    t.text "name"
    t.timestamptz "created_at"
    t.timestamptz "updated_at"
    t.text "family"
    t.index ["family"], name: "idx_2679858_index_llms_on_family", unique: true
  end

  create_table "mcp_servers", force: :cascade do |t|
    t.bigint "user_id"
    t.text "uuid"
    t.text "name"
    t.text "url"
    t.boolean "active", default: true
    t.text "server_name"
    t.text "server_version"
    t.text "protocol_version"
    t.timestamptz "last_fetched_at"
    t.text "last_error"
    t.timestamptz "created_at"
    t.timestamptz "updated_at"
    t.boolean "public", default: false
    t.text "encrypted_auth_token"
    t.index ["public"], name: "idx_2679888_index_mcp_servers_on_public"
    t.index ["user_id", "url"], name: "idx_2679888_index_mcp_servers_on_user_id_and_url", unique: true
    t.index ["user_id"], name: "idx_2679888_index_mcp_servers_on_user_id"
    t.index ["uuid"], name: "idx_2679888_index_mcp_servers_on_uuid", unique: true
  end

  create_table "mcp_tools", force: :cascade do |t|
    t.bigint "mcp_server_id"
    t.text "name"
    t.text "description"
    t.json "input_schema"
    t.boolean "active", default: true
    t.timestamptz "created_at"
    t.timestamptz "updated_at"
    t.json "annotations", default: {}
    t.index ["mcp_server_id", "name"], name: "idx_2679897_index_mcp_tools_on_mcp_server_id_and_name", unique: true
    t.index ["mcp_server_id"], name: "idx_2679897_index_mcp_tools_on_mcp_server_id"
  end

  create_table "users", force: :cascade do |t|
    t.text "email", default: ""
    t.text "google_id"
    t.timestamptz "created_at"
    t.timestamptz "updated_at"
    t.text "favorite_model_meta_ids", default: "[]"
    t.text "default_model_meta_id"
    t.index ["email"], name: "idx_2679865_index_users_on_email", unique: true
    t.index ["google_id"], name: "idx_2679865_index_users_on_google_id", unique: true
  end

  add_foreign_key "credit_transactions", "users"
  add_foreign_key "credit_transactions", "users", column: "granted_by_id"
  add_foreign_key "llm_api_keys", "users", name: "llm_api_keys_user_id_fkey"
  add_foreign_key "llm_models", "llms", name: "llm_models_llm_id_fkey"
  add_foreign_key "mcp_servers", "users", name: "mcp_servers_user_id_fkey"
  add_foreign_key "mcp_tools", "mcp_servers", name: "mcp_tools_mcp_server_id_fkey"
end
