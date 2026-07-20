class AddEncryptedAuthTokenToMcpServers < ActiveRecord::Migration[8.0]
  def change
    add_column :mcp_servers, :encrypted_auth_token, :text
  end
end
