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

  def set_mcp_server
    @mcp_server = current_user.mcp_servers.find_by!(uuid: params[:mcp_server_uuid])
  end

  def set_mcp_tool
    @mcp_tool = @mcp_server.mcp_tools.find(params[:id])
  end
end
