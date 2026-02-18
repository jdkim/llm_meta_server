class AddLlmTypeToLlms < ActiveRecord::Migration[8.0]
  def up
    add_column :llms, :llm_type, :string

    # Backfill llm_type from name (e.g., "OpenAI" -> "openai")
    execute <<~SQL
      UPDATE llms SET llm_type = LOWER(name)
    SQL

    change_column_null :llms, :llm_type, false
    add_index :llms, :llm_type, unique: true
  end

  def down
    remove_index :llms, :llm_type
    remove_column :llms, :llm_type
  end
end
