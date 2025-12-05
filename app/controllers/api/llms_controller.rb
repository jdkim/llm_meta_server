class Api::LlmsController < ApiController
  # Google ID Token authentication required

  def index
    # Return all available LLM services including Ollama
    render json: { llms: Llm.all_services_with_ollama }
  end
end
