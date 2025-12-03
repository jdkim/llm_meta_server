class Api::LlmApiKeysController < ApiController
  # Google ID Token authentication required

  def index
    # Return only user's registered API keys
    # For available LLM services (including Ollama), use /api/llms endpoint
    llm_api_keys = current_user.llm_api_keys.map(&:as_json)
    render json: { llm_api_keys: llm_api_keys }
  end
end
