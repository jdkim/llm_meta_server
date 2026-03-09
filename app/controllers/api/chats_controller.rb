class Api::ChatsController < ApiController
  # Google ID Token authentication required
  rescue_from LLM::RateLimitError, with: :rate_limit_error
  rescue_from LlmApiKeyRequiredError, with: :api_key_required_error
  rescue_from ArgumentError, with: :argument_error
  rescue_from McpClient::McpConnectionError, with: :mcp_connection_error
  rescue_from McpClient::McpProtocolError, with: :mcp_protocol_error

  def create
    uuid, model_name, prompt = expected_params

    if bearer_token
      llm_api_key = current_user.find_llm_api_key uuid
      model_id = LlmModelMap.fetch! model_name, llm_type: llm_api_key&.llm_type
      tools = selected_tools
      message = LlmRbFacade.call! model_id, prompt,
        llm_api_key: llm_api_key,
        tools: tools
    else
      model_id = LlmModelMap.fetch! model_name
      message = LlmRbFacade.call! model_id, prompt
    end

    render json: {
      response: format_response(message)
    }
  end

  private

  def rate_limit_error(exception)
    render json: { error: "LLM API Rate limit exceeded", message: exception.message }, status: :too_many_requests
  end

  def api_key_required_error(exception)
    render json: { error: "LLM API Key is required to use paid models", message: exception.message }, status: :bad_request
  end

  def argument_error(exception)
    render json: { error: "Invalid arguments", message: exception.message }, status: :bad_request
  end

  def mcp_connection_error(exception)
    render json: { error: "MCP server connection failed", message: exception.message }, status: :bad_gateway
  end

  def mcp_protocol_error(exception)
    render json: { error: "MCP protocol error", message: exception.message }, status: :bad_gateway
  end

  def expected_params
    params.expect(:llm_api_key_uuid, :model_name, :prompt)
  end

  def selected_tools
    tool_ids = params[:tool_ids]
    return [] if tool_ids.blank?

    mcp_tools = current_user.mcp_servers.active
      .joins(:mcp_tools)
      .merge(McpTool.active.where(id: tool_ids))
      .flat_map { it.mcp_tools.active.where(id: tool_ids).includes(:mcp_server) }

    McpToolAdapter.to_llm_functions(mcp_tools)
  end

  def format_response(result)
    if result.is_a?(Hash)
      result
    else
      { message: result }
    end
  end
end
