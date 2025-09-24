class AddDescriptionToLlmApiKeys < ActiveRecord::Migration[8.0]
  def change
    add_column :llm_api_keys, :description, :text
  end
end
