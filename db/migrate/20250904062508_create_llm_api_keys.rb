class CreateLlmApiKeys < ActiveRecord::Migration[8.0]
  def change
    create_table :llm_api_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :llm_type, null: false
      t.text :encrypted_api_key, null: false
      t.string :uuid, null: false

      t.timestamps
    end

    add_index :llm_api_keys, :uuid, unique: true
    add_index :llm_api_keys, [ :user_id, :llm_type ], unique: true
  end
end
