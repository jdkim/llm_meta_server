class Api::ChatsController < ApiController
  # JSON requests already send flat top-level keys; skip resource wrapping
  # so :chat doesn't appear as a duplicated, unpermitted parameter.
  wrap_parameters false

  # Google ID Token authentication required
  rescue_from LLM::RateLimitError, with: :rate_limit_error
  rescue_from LlmApiKeyRequiredError, with: :api_key_required_error
  rescue_from ArgumentError, with: :argument_error
  rescue_from ModelNotFoundError, with: :model_not_found_error
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
        tools: tools,
        generation_params: effective_generation_params(model_name, llm_api_key&.llm_type)
    else
      model_id = LlmModelMap.fetch! model_name
      message = LlmRbFacade.call! model_id, prompt,
        generation_params: effective_generation_params(model_name, nil)
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

  def model_not_found_error(exception)
    render json: { error: "Model not found", message: exception.message }, status: :not_found
  end

  def mcp_connection_error(exception)
    render json: { error: "MCP server connection failed", message: exception.message }, status: :bad_gateway
  end

  def mcp_protocol_error(exception)
    render json: { error: "MCP protocol error", message: exception.message }, status: :bad_gateway
  end

  def expected_params
    # permit first so the strong-params logger doesn't flag these as
    # unpermitted; expect still enforces presence + shape.
    params.permit(:llm_api_key_uuid, :model_name, :prompt, tool_ids: [])
    params.expect(:llm_api_key_uuid, :model_name, :prompt)
  end

  def selected_tools
    tool_ids = params.permit(tool_ids: [])[:tool_ids]
    return [] if tool_ids.blank?

    McpToolAdapter.to_llm_functions(McpTool.lookup(tool_ids, viewer: current_user))
  end

  # Pass-through: caller sends `generation_settings: {…}` (any keys/values),
  # and we hand the bag of params to LlmRbFacade → llm.rb → the provider.
  # The provider's normalize_complete_params decides what it understands.
  def generation_params
    raw = params[:generation_settings]
    return {} if raw.blank?
    hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    hash.deep_symbolize_keys
  end

  # Per-request generation_params layered over per-model defaults from the
  # catalog. Per-request values win — the catalog's `defaults:` block only
  # supplies a key when the caller didn't.
  # See Api::ChatStreamsController#effective_generation_params for why
  # this uses deep_merge (shallow merge would drop nested catalog defaults
  # like Ollama's `options.num_ctx` on any per-request options override).
  def effective_generation_params(model_name, llm_type)
    LlmModelMap.defaults_for(model_name, llm_type: llm_type).deep_merge(generation_params)
  end

  def format_response(result)
    if result.is_a?(Hash)
      result
    else
      { message: result.to_s }
    end
  end
end
