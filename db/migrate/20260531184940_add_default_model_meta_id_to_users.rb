class AddDefaultModelMetaIdToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :default_model_meta_id, :string
  end
end
