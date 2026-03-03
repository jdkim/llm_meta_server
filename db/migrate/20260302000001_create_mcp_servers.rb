class CreateMcpServers < ActiveRecord::Migration[8.0]
  def change
    create_table :mcp_servers do |t|
      t.references :user, null: false, foreign_key: true
      t.string :uuid, null: false
      t.string :name, null: false
      t.string :url, null: false
      t.boolean :active, null: false, default: true
      t.string :server_name
      t.string :server_version
      t.string :protocol_version
      t.datetime :last_fetched_at
      t.text :last_error

      t.timestamps
    end

    add_index :mcp_servers, :uuid, unique: true
    add_index :mcp_servers, [ :user_id, :url ], unique: true
  end
end
