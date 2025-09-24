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

ActiveRecord::Schema[8.0].define(version: 2025_09_18_082501) do
  create_table "llm_api_keys", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "llm_type", null: false
    t.text "encrypted_api_key", null: false
    t.string "uuid", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.index ["user_id", "llm_type"], name: "index_llm_api_keys_on_user_id_and_llm_type"
    t.index ["user_id"], name: "index_llm_api_keys_on_user_id"
    t.index ["uuid"], name: "index_llm_api_keys_on_uuid", unique: true
  end

  create_table "llm_models", force: :cascade do |t|
    t.integer "llm_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["llm_id"], name: "index_llm_models_on_llm_id"
  end

  create_table "llms", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "google_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["google_id"], name: "index_users_on_google_id", unique: true
  end

  add_foreign_key "llm_api_keys", "users"
  add_foreign_key "llm_models", "llms"
end
