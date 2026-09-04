# frozen_string_literal: true

module Admin
  # Cross-user view of registered MCP servers.
  #
  # Exists because the per-user screen cannot show the two problems that
  # actually bite: the same upstream URL registered by several people (which
  # duplicates every tool name in the picker) and registrations whose tool list
  # was fetched long ago (which advertise tools the server no longer has).
  class McpServersController < BaseController
    STALE_AFTER = 30.days

    before_action :set_server, only: %i[refetch toggle_active]

    def index
      @servers = McpServer.includes(:user, :mcp_tools).order(:url, :id)
      @duplicate_urls = @servers.group_by(&:url).select { |_, rows| rows.size > 1 }.keys
      @stale_after = STALE_AFTER
    end

    def refetch
      McpToolFetcher.new(@server).fetch!
      redirect_to admin_mcp_servers_path,
                  notice: "Refetched #{@server.name} — #{@server.mcp_tools.count} tools"
    rescue StandardError => e
      redirect_to admin_mcp_servers_path, alert: "Refetch failed: #{e.message}"
    end

    def toggle_active
      @server.update!(active: !@server.active)
      redirect_to admin_mcp_servers_path,
                  notice: "#{@server.name} is now #{@server.active? ? 'active' : 'inactive'}"
    end

    private

    def set_server
      @server = McpServer.find(params[:id])
    end
  end
end
