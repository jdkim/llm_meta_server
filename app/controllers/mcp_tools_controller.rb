class McpToolsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_mcp_server
  before_action :set_mcp_tool, only: [ :toggle ]

  def index
    fetcher = McpToolFetcher.new(@mcp_server)
    fetcher.fetch!
    redirect_to user_mcp_servers_path(current_user), notice: "Tools fetched successfully from '#{@mcp_server.name}'"
  rescue McpClient::McpConnectionError, McpClient::McpProtocolError => e
    redirect_to user_mcp_servers_path(current_user), alert: "Failed to fetch tools: #{e.message}"
  end

  def toggle
    @mcp_tool.update!(active: !@mcp_tool.active)
    status = @mcp_tool.active? ? "activated" : "deactivated"
    redirect_to user_mcp_servers_path(current_user), notice: "Tool '#{@mcp_tool.name}' has been #{status}"
  end

  private

  def set_mcp_server
    @mcp_server = current_user.mcp_servers.find(params[:mcp_server_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to user_mcp_servers_path(current_user), alert: "The specified MCP server was not found"
  end

  def set_mcp_tool
    @mcp_tool = @mcp_server.mcp_tools.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to user_mcp_servers_path(current_user), alert: "The specified tool was not found"
  end
end
