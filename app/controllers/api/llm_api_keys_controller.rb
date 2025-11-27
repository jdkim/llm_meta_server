class Api::LlmApiKeysController < ApiController
  # Google ID Token authentication required

  def index
    render_llm_api_keys current_user
  end

  private

  def render_llm_api_keys(user)
    api_keys = user.llm_api_keys.map(&:as_json)

    # Automatically include Ollama (local) if not already present
    unless user.llm_api_keys.any? { |key| key.llm_type == "ollama" }
      api_keys << build_default_ollama_json
    end

    render json: {
      llm_api_keys: api_keys
    }
  end

  def build_default_ollama_json
    {
      llm_type: "ollama",
      description: "Local Ollama (no API key required)",
      uuid: "ollama-local"
    }
  end
end
