class AddPublicToMcpServers < ActiveRecord::Migration[8.0]
  def change
    add_column :mcp_servers, :public, :boolean, default: false, null: false
    add_index :mcp_servers, :public, where: "public = 1"
  end
end
