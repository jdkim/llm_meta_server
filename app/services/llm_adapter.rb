require "llm"

class LlmAdapter
  STRATEGIES = {
    "ollama" => :ollama,
    "openai" => :openai,
    "anthropic" => :anthropic,
    "google" => :gemini
  }.freeze

  class << self
    def call(llm_type, encryptable_api_key, model_name, prompt)
      llm = build_llm llm_type.lowercase, encryptable_api_key
      model_id = find_model_id llm, model_name

      execute_chat llm, model_id, prompt
    end

    private

    def find_model_id(llm, model_name)
      model = llm.models.all.find { |m| m.id == model_name }
      raise ModelNotFoundError, model_name unless model

      model.id
    end

    def build_llm(llm_type, encryptable_api_key)
      llm_method = STRATEGIES[llm_type]
      raise NotSupportedLlmError, llm_type unless llm_method

      # public_send dynamically invokes a public method on an object
      # Example: LLM.public_send(:openai, key: "xxx") is equivalent to LLM.openai(key: "xxx")
      # Unlike send, public_send cannot call private methods (safer)
      # Here, it calls one of :ollama, :openai, :anthropic, or :gemini based on llm_type
      # This eliminates the need for separate files for each LLM service
      LLM.public_send llm_method, key: encryptable_api_key.plain_api_key
    end

    def execute_chat(llm, model_id, prompt)
      bot = LLM::Bot.new llm, model: model_id
      messages = bot.chat { |p| p.user prompt }

      messages.map { _1.content }.join("\n")
    end
  end
end
