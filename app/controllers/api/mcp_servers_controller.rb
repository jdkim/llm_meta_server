class Api::McpServersController < ApiController
  before_action :set_mcp_server, only: [ :update, :destroy, :toggle, :toggle_public ]

  def index
    # Owned + others' public+active. Each row carries `owned: true/false`.
    # For non-owned (shared) entries, also expose `shared_by` (the owner's
    # email) so the requester can judge trust before invoking the tools —
    # the owner consented to attribution when they toggled the server
    # public.
    visible = McpServer.visible_to(current_user).includes(:mcp_tools, :user)
    payload = visible.map do |s|
      owned = (s.user_id == current_user.id)
      base  = s.as_json.merge("owned" => owned)
      owned ? base : base.merge("shared_by" => s.user.email)
    end
    render json: { mcp_servers: payload }
  end

  def create
    mcp_server = current_user.mcp_servers.create!(mcp_server_params)
    render json: mcp_server.as_json.merge("owned" => true), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    @mcp_server.update!(mcp_server_params)
    render json: @mcp_server.as_json.merge("owned" => true)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    @mcp_server.destroy!
    render json: { message: "MCP server deleted" }
  end

  def toggle
    @mcp_server.update!(active: !@mcp_server.active)
    render json: @mcp_server.as_json.merge("owned" => true)
  end

  def toggle_public
    @mcp_server.update!(public: !@mcp_server.public)
    render json: @mcp_server.as_json.merge("owned" => true)
  end

  private

  # Mutating actions are owner-only. Looking up via current_user.mcp_servers
  # guarantees a non-owner gets RecordNotFound (404), not 403 — same shape
  # as a wholly-unknown UUID, which is what we want for opaque resources.
  def set_mcp_server
    @mcp_server = current_user.mcp_servers.find_by!(uuid: params[:uuid])
  end

  def mcp_server_params
    params.expect(mcp_server: [ :name, :url ])
  end
end
