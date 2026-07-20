class AddAnnotationsToMcpTools < ActiveRecord::Migration[8.0]
  def change
    add_column :mcp_tools, :annotations, :json, default: {}
  end
end
