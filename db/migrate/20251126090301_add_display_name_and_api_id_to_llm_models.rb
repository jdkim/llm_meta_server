class AddDisplayNameAndApiIdToLlmModels < ActiveRecord::Migration[8.0]
  def change
    add_column :llm_models, :display_name, :string
    add_column :llm_models, :api_id, :string
  end
end
