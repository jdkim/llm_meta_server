class Api::LlmApiKeysController < ApiController
  # Google ID Token authentication required

  def index
    render_llm_api_keys current_user
  end

  private

  def render_llm_api_keys(user)
    api_keys = user.llm_api_keys_with_ollama
    render json: {
      llm_api_keys: api_keys
    }
  end
end
