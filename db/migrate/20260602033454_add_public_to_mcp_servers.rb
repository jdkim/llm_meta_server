class AddPublicToMcpServers < ActiveRecord::Migration[8.0]
  def change
    add_column :mcp_servers, :public, :boolean, default: false, null: false
    # Partial index — `public = TRUE` works on both Postgres and SQLite
    # (SQLite parses TRUE as 1). Avoids `public = 1`, which Postgres
    # rejects as a boolean=integer comparison.
    add_index :mcp_servers, :public, where: "public = TRUE"
  end
end
