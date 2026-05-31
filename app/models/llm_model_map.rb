class LlmModelMap
  # Catalog source of truth. To add / remove / rename a model, edit
  # config/llm_models.yml — no code change.
  CATALOG_PATH = Rails.root.join("config", "llm_models.yml")

  # Loaded once at class definition. The shape mirrors what the old
  # MODEL_MAP_<FAMILY> constants used to produce:
  #
  #   { "openai" => { "gpt-5" => { api_id:, display_name:, supports_vision:, kind: }, ... },
  #     "ollama" => { ... },
  #     ... }
  # deep_symbolize_keys (not transform_keys) so nested `defaults:` blocks come
  # through with symbol keys — they're splatted as keyword args into
  # LLM::Session.new further down the stack.
  MODEL_MAP = YAML.safe_load_file(CATALOG_PATH, permitted_classes: [ Symbol ])
                  .transform_values { |models|
                    models.transform_values(&:deep_symbolize_keys)
                  }
                  .freeze

  def self.fetch!(meta_id, llm_type: nil)
    model_data = MODEL_MAP.dig(llm_type || "ollama", meta_id)
    raise ModelNotFoundError, meta_id if model_data.nil?
    model_data[:api_id]
  end

  # Per-model generation-parameter defaults from the catalog. Returns an
  # empty hash when none are declared. Callers merge these UNDER user-
  # supplied params (so a per-request value wins).
  def self.defaults_for(meta_id, llm_type: nil)
    MODEL_MAP.dig(llm_type || "ollama", meta_id, :defaults) || {}
  end

  # Which HTTP endpoint the provider should use for this model.
  # Returns "chat_completions" by default; "responses" routes the OpenAI
  # streaming path through llm.responses.create (so reasoning summaries
  # can stream — they're hidden behind the chat completions endpoint).
  def self.endpoint_for(meta_id, llm_type: nil)
    MODEL_MAP.dig(llm_type || "ollama", meta_id, :endpoint).to_s.presence || "chat_completions"
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
    MODEL_MAP.fetch("ollama", {}).each_value.any? { |m| m[:api_id] == model_id }
  end

  def self.image_model?(meta_id, llm_type: nil)
    MODEL_MAP.dig(llm_type || "ollama", meta_id, :kind).to_s == "image"
  end

  def self.supports_vision?(meta_id, llm_type: nil)
    MODEL_MAP.dig(llm_type || "ollama", meta_id, :supports_vision) == true
  end
end
