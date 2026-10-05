# Proxy endpoint for the client-orchestrated flow: when the LLM (via
# Api::SingleLlmCallsController) emits a remote MCP tool_call, the JS client
# posts here to execute it. Keeps the MCP-server URL + auth_token server-side
# — the client never sees them — while giving it the same call semantics as
# the hub-run tool loop in Api::ChatStreamsController.
#
# Visibility mirrors LlmRbFacade's tool-selection path: McpTool.lookup allows
# a user to invoke any active tool from a server that is either theirs or
# public+active. Anonymous callers may invoke only public_to_anonymous
# servers. Ownership is NOT required.
class Api::McpToolCallsController < ApiController
  include AnonymousUsageGuard

  wrap_parameters false

  rescue_from McpClient::McpConnectionError, with: :mcp_connection_error
  rescue_from McpClient::McpProtocolError,   with: :mcp_protocol_error

  def create
    # bearer-guard, as in single_llm_calls: an anonymous caller that was
    # offered a public_to_anonymous tool must also be able to EXECUTE it.
    viewer = bearer_token.present? ? current_user : nil
    tool = McpTool.lookup([ params[:tool_id] ], viewer: viewer).first
    raise ActiveRecord::RecordNotFound if tool.nil?

    unless viewer
      usage_policy.validate_arguments!(params[:arguments])
      permit = usage_policy.acquire!(kind: "mcp", ip: request.remote_ip, tool: tool)
    end
    arguments = arguments_param
    operation = -> {
      server = tool.mcp_server
      client = McpClient.new(server.url, auth_token: server.auth_token, caller_ip: request.remote_ip,
        max_response_bytes: permit && permit[:result_bytes])
      client.initialize_connection!
      client.call_tool!(tool.name, arguments)
    }
    result = permit ? usage_policy.run(permit, &operation) : operation.call
    if permit && result.to_json.bytesize > permit[:result_bytes]
      raise AnonymousUsagePolicy::Rejected.new("result_too_large", "MCP result exceeds the configured limit", status: 502)
    end

    render json: { result: result }
  rescue AnonymousUsagePolicy::Rejected => e
    render_usage_rejection(e)
  rescue AnonymousUsagePolicy::Cancelled => e
    render json: { error: e.is_a?(AnonymousUsagePolicy::DeadlineExceeded) ? "execution_timeout" : "stopped", message: e.message }, status: :gateway_timeout
  ensure
    usage_policy.release!(permit) if permit
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
