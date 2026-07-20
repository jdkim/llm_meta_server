class McpServersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_mcp_server, only: [ :update, :destroy, :toggle, :toggle_public ]

  def index
    @mcp_servers = current_user.mcp_servers.includes(:mcp_tools)
  end

  def create
    current_user.mcp_servers.create!(mcp_server_params)
    redirect_to user_mcp_servers_path(current_user), notice: "MCP server has been added successfully"
  rescue ActionController::ParameterMissing
    redirect_to user_mcp_servers_path(current_user), alert: "Please enter server name and URL"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to user_mcp_servers_path(current_user), alert: "Failed to add MCP server: #{e.message}"
  end

  def update
    @mcp_server.update!(mcp_server_params)
    redirect_to user_mcp_servers_path(current_user), notice: "MCP server has been updated successfully"
  rescue ActionController::ParameterMissing
    redirect_to user_mcp_servers_path(current_user), alert: "Please enter server name and URL"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to user_mcp_servers_path(current_user), alert: "Failed to update MCP server: #{e.message}"
  end

  def destroy
    @mcp_server.destroy!
    redirect_to user_mcp_servers_path(current_user), notice: "MCP server '#{@mcp_server.name}' has been deleted successfully"
  rescue ActiveRecord::RecordNotDestroyed
    redirect_to user_mcp_servers_path(current_user), alert: "Failed to delete MCP server"
  end

  def toggle
    @mcp_server.update!(active: !@mcp_server.active)
    status = @mcp_server.active? ? "activated" : "deactivated"
    redirect_to user_mcp_servers_path(current_user), notice: "MCP server '#{@mcp_server.name}' has been #{status}"
  end

  def toggle_public
    @mcp_server.update!(public: !@mcp_server.public)
    visibility = @mcp_server.public? ? "public — visible to all signed-in users" : "private"
    redirect_to user_mcp_servers_path(current_user), notice: "MCP server '#{@mcp_server.name}' is now #{visibility}"
  end

  private

  def set_mcp_server
    @mcp_server = current_user.mcp_servers.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to user_mcp_servers_path(current_user), alert: "The specified MCP server was not found"
  end

  def mcp_server_params
    permitted = params.expect(mcp_server: [ :name, :url, :auth_token ])
    permitted.delete(:auth_token) if permitted[:auth_token].blank? && action_name == "update"
    permitted
  end
end
