class CreateModelCatalogChecks < ActiveRecord::Migration[8.0]
  def change
    create_table :model_catalog_checks do |t|
      t.string :provider, null: false
      t.timestamptz :checked_at, null: false
      t.jsonb   :new_in_provider, null: false, default: []
      t.jsonb   :missing_from_provider, null: false, default: []
      t.string  :error
      t.timestamps
    end
    add_index :model_catalog_checks, [ :provider, :checked_at ]
  end
end
