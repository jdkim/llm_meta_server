class AddPublicToAnonymousToMcpServers < ActiveRecord::Migration[8.0]
  def change
    add_column :mcp_servers, :public_to_anonymous, :boolean, default: false, null: false
  end
end
