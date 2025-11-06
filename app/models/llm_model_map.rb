
class LlmModelMap
  MODEL_MAP_OPENAI = {
    # OpenAI Models
    "gpt-4o" => { api_id: "gpt-4o", display_name: "GPT-4o" },
    "gpt-4o-mini" => { api_id: "gpt-4o-mini", display_name: "GPT-4o Mini" },
    "gpt-4-turbo" => { api_id: "gpt-4-turbo", display_name: "GPT-4 Turbo" },
    "gpt-3-5-turbo" => { api_id: "gpt-3.5-turbo", display_name: "GPT-3.5 Turbo" },
    "gpt-3-5-turbo-16k" => { api_id: "gpt-3.5-turbo-16k", display_name: "GPT-3.5 Turbo 16K" }
  }
  MODEL_MAP_ANTHROPIC = {
    # Anthropic Models
    "claude-sonnet-4-5" => { api_id: "claude-sonnet-4-5", display_name: "Claude Sonnet 4.5" },
    "claude-haiku-4-5" => { api_id: "claude-haiku-4-5", display_name: "Claude Haiku 4.5" },
    "claude-opus-4-1" => { api_id: "claude-opus-4-1", display_name: "Claude Opus 4.1" },
    "claude-sonnet-4-0" => { api_id: "claude-sonnet-4-0", display_name: "Claude Sonnet 4" },
    "claude-sonnet-3-7" => { api_id: "claude-3-7-sonnet-latest", display_name: "Claude Sonnet 3.7" },
    "claude-opus-4-0" => { api_id: "claude-opus-4-0", display_name: "Claude Opus 4" },
    "claude-3-5-haiku-latest" => { api_id: "claude-3-5-haiku-latest", display_name: "Claude 3.5 Haiku" },
    "claude-3-haiku" => { api_id: "claude-3-haiku-20240307", display_name: "Claude 3 Haiku" },
  }
  MODEL_MAP_GOOGLE = {
    # Google Gemini Models
    "gemini-2-5-pro" => { api_id: "gemini-2.5-pro", display_name: "Gemini 2.5 Pro" },
    "gemini-2-5-flash" => { api_id: "gemini-2.5-flash", display_name: "Gemini 2.5 Flash" },
    "gemini-2-5-flash-lite" => { api_id: "gemini-2.5-flash-lite", display_name: "Gemini 2.5 Flash Lite" },
    "gemini-2-0-flash" => { api_id: "gemini-2.0-flash", display_name: "Gemini 2.0 Flash" },
    "gemini-2-0-flash-lite" => { api_id: "gemini-2.0-flash-lite", display_name: "Gemini 2.0 Flash Lite" }
  }
  MODEL_MAP_OLLAMA = {
    # Ollama Models
    # :
  }

  MODEL_MAP = {
    "openai" => MODEL_MAP_OPENAI,
    "anthropic" => MODEL_MAP_ANTHROPIC,
    "google" => MODEL_MAP_GOOGLE,
    "ollama" => MODEL_MAP_OLLAMA
  }

  def self.fetch!(llm_type, meta_id)
    model_data = MODEL_MAP.dig(llm_type, meta_id)
    model_data[:api_id]
  end

  def self.available_models_for(llm_type)
    MODEL_MAP.fetch(llm_type).map do |key, value|
      display_name = value[:display_name]
      {
        "label" => display_name, # Display name: Show the official model name
        "value" => key # Internal ID: Model ID to pass to API (without dots)
      }
    end
  end
end
