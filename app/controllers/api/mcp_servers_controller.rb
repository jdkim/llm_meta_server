class Api::McpServersController < ApiController
  before_action :set_mcp_server, only: [ :update, :destroy, :toggle ]

  def index
    mcp_servers = current_user.mcp_servers.map(&:as_json)
    render json: { mcp_servers: mcp_servers }
  end

  def create
    mcp_server = current_user.mcp_servers.create!(mcp_server_params)
    render json: mcp_server.as_json, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    @mcp_server.update!(mcp_server_params)
    render json: @mcp_server.as_json
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    @mcp_server.destroy!
    render json: { message: "MCP server deleted" }
  end

  def toggle
    @mcp_server.update!(active: !@mcp_server.active)
    render json: @mcp_server.as_json
  end

  private

  def set_mcp_server
    @mcp_server = current_user.mcp_servers.find_by!(uuid: params[:uuid])
  end

  def mcp_server_params
    params.expect(mcp_server: [ :name, :url ])
  end
end
