class Api::McpToolsController < ApiController
  before_action :set_mcp_server
  before_action :set_mcp_tool, only: [ :toggle ]

  def index
    fetcher = McpToolFetcher.new(@mcp_server)
    fetcher.fetch!
    render json: { tools: @mcp_server.mcp_tools.reload.map(&:as_json) }
  rescue McpClient::McpConnectionError, McpClient::McpProtocolError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  def toggle
    @mcp_tool.update!(active: !@mcp_tool.active)
    render json: @mcp_tool.as_json
  end

  private

  # Signed-in callers can see their own MCP servers + any `public` server.
  # Anon callers (no bearer) can see only `public_to_anonymous` servers.
  # Either way, only allow toggling (:toggle action) if the caller owns it —
  # `toggle` also runs current_user.mcp_servers.find_by! inside set_mcp_tool.
  def set_mcp_server
    scope = bearer_token.present? ? McpServer.visible_to(current_user) : McpServer.visible_to(nil)
    @mcp_server = scope.find_by!(uuid: params[:mcp_server_uuid])
  end

  def set_mcp_tool
    @mcp_tool = @mcp_server.mcp_tools.find(params[:id])
  end
end
