class CreateAnonymousUsageStates < ActiveRecord::Migration[8.0]
  def change
    create_table :anonymous_usage_states do |t|
      t.string :scope, null: false
      t.jsonb :state, null: false, default: {}
      t.timestamps
    end
    add_index :anonymous_usage_states, :scope, unique: true
  end
end
