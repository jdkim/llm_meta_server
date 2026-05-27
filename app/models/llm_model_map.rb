class LlmModelMap
  MODEL_MAP_OPENAI = {
    # OpenAI Models
    "gpt-5" => { api_id: "gpt-5", display_name: "GPT-5", supports_vision: true },
    "gpt-5-mini" => { api_id: "gpt-5-mini", display_name: "GPT-5 Mini", supports_vision: true }
  }
  MODEL_MAP_ANTHROPIC = {
    # Anthropic Models
    "claude-opus-4-7" => { api_id: "claude-opus-4-7", display_name: "Claude Opus 4.7", supports_vision: true },
    "claude-sonnet-4-6" => { api_id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6", supports_vision: true },
    "claude-haiku-4-5" => { api_id: "claude-haiku-4-5", display_name: "Claude Haiku 4.5", supports_vision: true }
  }
  MODEL_MAP_GOOGLE = {
    # Google Gemini Models
    "gemini-3-1-pro" => { api_id: "gemini-3.1-pro-preview", display_name: "Gemini 3.1 Pro", supports_vision: true },
    "gemini-3-pro" => { api_id: "gemini-3-pro-preview", display_name: "Gemini 3 Pro", supports_vision: true },
    "gemini-3-flash" => { api_id: "gemini-3-flash-preview", display_name: "Gemini 3 Flash", supports_vision: true },
    "gemini-2-5-pro" => { api_id: "gemini-2.5-pro", display_name: "Gemini 2.5 Pro", supports_vision: true },
    "gemini-3-1-flash-image" => { api_id: "gemini-3.1-flash-image-preview", display_name: "Gemini 3.1 Flash Image (Nano Banana 2)", kind: :image, supports_vision: true },
    "gemini-3-pro-image" => { api_id: "gemini-3-pro-image-preview", display_name: "Gemini 3 Pro Image (Nano Banana Pro)", kind: :image, supports_vision: true },
    "gemini-2-5-flash-image" => { api_id: "gemini-2.5-flash-image", display_name: "Gemini 2.5 Flash Image (Nano Banana)", kind: :image, supports_vision: true }
  }
  MODEL_MAP_OLLAMA = {
    # Ollama Models
    "qwen3-6-35b" => { api_id: "qwen3.6:35b", display_name: "qwen3.6:35b", supports_vision: true },
    "qwen3-5-9b" => { api_id: "qwen3.5:9b", display_name: "qwen3.5:9b" },
    "qwen3-5-4b" => { api_id: "qwen3.5:4b", display_name: "qwen3.5:4b" },
    "gemma3-27b" => { api_id: "gemma3:27b", display_name: "gemma3:27b" }
  }

  MODEL_MAP = {
    "openai" => MODEL_MAP_OPENAI,
    "anthropic" => MODEL_MAP_ANTHROPIC,
    "google" => MODEL_MAP_GOOGLE,
    "ollama" => MODEL_MAP_OLLAMA
  }

  def self.fetch!(meta_id, llm_type: nil)
    model_data = MODEL_MAP.dig(llm_type || "ollama", meta_id)
    model_data[:api_id]
  end

  def self.available_models_for(llm_type)
    MODEL_MAP.fetch(llm_type).map do |key, value|
      {
        "label" => value[:display_name], # Display name: official model name
        "value" => key,                   # Internal ID: meta_id (without dots)
        "supports_vision" => value[:supports_vision] == true
      }
    end
  end

  def self.ollama_model?(model_id)
    MODEL_MAP_OLLAMA.values.any? { |m| m[:api_id] == model_id }
  end

  def self.image_model?(meta_id, llm_type: nil)
    MODEL_MAP.dig(llm_type || "ollama", meta_id, :kind) == :image
  end

  def self.supports_vision?(meta_id, llm_type: nil)
    MODEL_MAP.dig(llm_type || "ollama", meta_id, :supports_vision) == true
  end
end
