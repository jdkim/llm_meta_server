class Api::ChatsController < ApiController
  # Google ID Token authentication required
  rescue_from LLM::RateLimitError, with: :rate_limit_error
  rescue_from LlmApiKeyRequiredError, with: :api_key_required_error
  rescue_from ArgumentError, with: :argument_error
  rescue_from McpClient::McpConnectionError, with: :mcp_connection_error
  rescue_from McpClient::McpProtocolError, with: :mcp_protocol_error

  GENERATION_PARAM_KEYS = %i[temperature top_p top_k max_tokens].freeze

  def create
    uuid, model_name, prompt = expected_params

    if bearer_token
      llm_api_key = current_user.find_llm_api_key uuid
      model_id = LlmModelMap.fetch! model_name, llm_type: llm_api_key&.llm_type
      tools = selected_tools
      message = LlmRbFacade.call! model_id, prompt,
        llm_api_key: llm_api_key,
        tools: tools,
        generation_params: generation_params
    else
      model_id = LlmModelMap.fetch! model_name
      message = LlmRbFacade.call! model_id, prompt,
        generation_params: generation_params
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

    McpToolAdapter.to_llm_functions(current_user.find_mcp_tools(tool_ids))
  end

  def generation_params
    params.permit(*GENERATION_PARAM_KEYS).to_h.symbolize_keys
  end

  def format_response(result)
    if result.is_a?(Hash)
      result
    else
      { message: result.to_s }
    end
  end
end
