class McpToolFetcher
  attr_reader :mcp_server

  def initialize(mcp_server)
    @mcp_server = mcp_server
  end

  def fetch!
    client = McpClient.new(mcp_server.url)

    client.initialize_connection!

    mcp_server.update!(
      server_name: client.server_info&.dig("name"),
      server_version: client.server_info&.dig("version"),
      protocol_version: client.protocol_version
    )

    tools = client.list_tools!
    sync_tools!(tools)

    mcp_server.update!(last_fetched_at: Time.current, last_error: nil)

    tools
  rescue McpClient::McpConnectionError, McpClient::McpProtocolError => e
    mcp_server.update!(last_error: e.message)
    raise
  end

  private

  def sync_tools!(tools)
    fetched_names = tools.map { it["name"] }

    mcp_server.mcp_tools.where.not(name: fetched_names).destroy_all

    tools.each do |tool_data|
      existing = mcp_server.mcp_tools.find_by(name: tool_data["name"])

      if existing
        existing.update!(
          description: tool_data["description"],
          input_schema: tool_data["inputSchema"] || {}
        )
      else
        mcp_server.mcp_tools.create!(
          name: tool_data["name"],
          description: tool_data["description"],
          input_schema: tool_data["inputSchema"] || {}
        )
      end
    end
  end
end
