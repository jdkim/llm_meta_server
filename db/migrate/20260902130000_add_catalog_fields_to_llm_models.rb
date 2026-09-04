# Consolidates the model catalog into the database.
#
# Until now there were two lists: this table (served by /api/llms, and stale —
# still advertising gpt-4o and gemini-2.0) and config/llm_models.yml (loaded
# once at boot into a frozen LlmModelMap::MODEL_MAP, and authoritative). The
# YAML could only be changed by editing a git-tracked file and restarting, so
# it could never be managed from the admin UI. Moving the catalog here makes it
# editable at runtime and leaves one source of truth.
#
# `notes` carries the explanatory comments the YAML accumulated (why Haiku
# rejects adaptive thinking, why gpt-5.5-pro is responses_only) so that
# knowledge survives the move.
class AddCatalogFieldsToLlmModels < ActiveRecord::Migration[8.0]
  def change
    change_table :llm_models, bulk: true do |t|
      t.boolean :supports_vision, null: false, default: false
      t.boolean :supports_tools,  null: false, default: false
      t.boolean :responses_only,  null: false, default: false
      t.boolean :active,          null: false, default: true
      t.text    :kind
      t.text    :endpoint
      t.jsonb   :defaults, null: false, default: {}
      t.jsonb   :pricing,  null: false, default: {}
      t.text    :notes
      t.integer :position, null: false, default: 0
    end

    add_index :llm_models, [ :llm_id, :name ], unique: true
  end
end
