class AddFavoriteModelMetaIdsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :favorite_model_meta_ids, :text, default: "[]", null: false
  end
end
