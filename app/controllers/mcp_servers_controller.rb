class McpServersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_mcp_server, only: [ :update, :destroy, :toggle, :toggle_public, :toggle_public_to_anonymous ]
  # Publishing a server exposes its tools to other users' chats. The same
  # upstream server is often registered by several users, so leaving this
  # open produces duplicate tool names in every consumer's picker. Restrict
  # both visibility tiers to super_users; owners keep full control of
  # everything else about their own servers.
  before_action :require_super_user!, only: [ :toggle_public, :toggle_public_to_anonymous ]

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
  rescue ActiveRecord::RecordInvalid => e
    redirect_to user_mcp_servers_path(current_user), alert: "Cannot change visibility of '#{@mcp_server.name}': #{e.record.errors.full_messages.to_sentence}"
  end

  # Second-tier visibility: within a public server, further opt in to being
  # invokable by unsigned (no-bearer) chat callers. The caller's originating
  # IP is still forwarded to the MCP server via X-Forwarded-For; only the
  # user's identity is absent. Guarded by `anonymous_visibility_requires_public`
  # on the model.
  def toggle_public_to_anonymous
    @mcp_server.update!(public_to_anonymous: !@mcp_server.public_to_anonymous)
    scope = @mcp_server.public_to_anonymous? ? "signed-in users AND unsigned visitors" : "signed-in users only"
    redirect_to user_mcp_servers_path(current_user), notice: "MCP server '#{@mcp_server.name}' is now invokable by #{scope}"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to user_mcp_servers_path(current_user), alert: "Cannot change sign-in requirement of '#{@mcp_server.name}': #{e.record.errors.full_messages.to_sentence}"
  end

  private

  def set_mcp_server
    @mcp_server = current_user.mcp_servers.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to user_mcp_servers_path(current_user), alert: "The specified MCP server was not found"
  end

  def require_super_user!
    return if current_user.super_user?
    redirect_to user_mcp_servers_path(current_user),
                alert: "Only an administrator can change an MCP server's visibility"
  end

  def mcp_server_params
    permitted = params.expect(mcp_server: [ :name, :url, :auth_token, :public_to_anonymous ])
    permitted.delete(:auth_token) if permitted[:auth_token].blank? && action_name == "update"
    # create/update must not become a side door around require_super_user!
    permitted.delete(:public_to_anonymous) unless current_user.super_user?
    permitted
  end
end
