class CreateLlmApiKeys < ActiveRecord::Migration[8.0]
  def change
    create_table :llm_api_keys do |t|
      t.references :user, null: false, foreign_key: true

      t.string :uuid, null: false
      t.string :llm_type, null: false
      t.string :encrypted_api_key, null: false

      t.timestamps
    end

    add_index :llm_api_keys, :uuid, unique: true
  end
end
