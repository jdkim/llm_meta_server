class AddLlmTypeToLlms < ActiveRecord::Migration[8.0]
  def up
    add_column :llms, :family, :string

    # Backfill family from name (e.g., "OpenAI" -> "openai")
    execute <<~SQL
      UPDATE llms SET family = LOWER(name)
    SQL

    change_column_null :llms, :family, false
    add_index :llms, :family, unique: true
  end

  def down
    remove_index :llms, :family
    remove_column :llms, :family
  end
end
