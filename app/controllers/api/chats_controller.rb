class Api::ChatsController < ApiController
  # Google ID Token authentication required
  rescue_from LLM::RateLimitError, with: :rate_limit_error

  def create
    uuid, model_name, prompt = expected_params
    llm_api_key = find_or_build_llm_api_key(uuid)
    model_id = LlmModelMap.fetch! llm_api_key.llm_type, model_name
    message = LlmRbFacade.call! llm_api_key, model_id, prompt

    render json: {
      response: {
        message: message
      }
    }
  end

  private

  def find_or_build_llm_api_key(uuid)
    # Ollama is a local service without persistence requirement
    if uuid == "ollama-local"
      LlmApiKey.new(
        user: current_user,
        llm_type: "ollama",
        uuid: "ollama-local"
      )
    else
      current_user.find_llm_api_key!(uuid)
    end
  end

  def rate_limit_error(exception)
    render json: { error: "LLM API Rate limit exceeded", message: exception.message }, status: :too_many_requests
  end

  def expected_params
    params.expect(:llm_api_key_uuid, :model_name, :prompt)
  end
end
