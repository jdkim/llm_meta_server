class Api::LlmsController < ApiController
  # Google ID Token authentication required

  def index
    # Return all available LLM services including Ollama
    llms = build_llm_services_list
    render json: { llms: llms }
  end

  private

  def build_llm_services_list
    # Get all registered LLM services with their models
    registered_llms = Llm.includes(:llm_models).all.map(&:as_json)

    # Add Ollama as a special service (no API key required)
    ollama_service = Llm.default_ollama_json

    registered_llms << ollama_service
  end
end

