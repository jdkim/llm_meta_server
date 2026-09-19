# Proxy endpoint for the client-orchestrated flow: when the LLM (via
# Api::SingleLlmCallsController) emits a remote MCP tool_call, the JS client
# posts here to execute it. Keeps the MCP-server URL + auth_token server-side
# — the client never sees them — while giving it the same call semantics as
# the hub-run tool loop in Api::ChatStreamsController.
#
# Visibility mirrors LlmRbFacade's tool-selection path: McpTool.lookup allows
# a user to invoke any active tool from a server that is either theirs or
# public+active. Ownership is NOT required.
class Api::McpToolCallsController < ApiController
  wrap_parameters false

  rescue_from McpClient::McpConnectionError, with: :mcp_connection_error
  rescue_from McpClient::McpProtocolError,   with: :mcp_protocol_error

  def create
    tool = McpTool.lookup([ params[:tool_id] ], viewer: current_user).first
    raise ActiveRecord::RecordNotFound if tool.nil?

    server = tool.mcp_server
    client = McpClient.new(server.url, auth_token: server.auth_token)
    client.initialize_connection!
    result = client.call_tool!(tool.name, arguments_param)

    render json: { result: result }
  end

  private

  def arguments_param
    raw = params[:arguments]
    return {} if raw.blank?
    hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    hash.deep_symbolize_keys
  end

  def mcp_connection_error(exception)
    render json: { error: "MCP server connection failed", message: exception.message }, status: :bad_gateway
  end

  def mcp_protocol_error(exception)
    render json: { error: "MCP protocol error", message: exception.message }, status: :bad_gateway
  end
end
