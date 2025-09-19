class RemoveUniqueIndexFromLlmApiKeys < ActiveRecord::Migration[8.0]
  def change
    # Remove unique index defined in 20250904062508_create_llm_api_keys.rb
    remove_index :llm_api_keys, [ :user_id, :llm_type ]

    # Add regular index without unique constraint
    add_index :llm_api_keys, [ :user_id, :llm_type ]
  end
end
