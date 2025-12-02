module LlmRbFacade
  class << self
    def call!(llm_api_key, model_id, prompt)
      llm = create_llm_client llm_api_key, model_id
      execute_chat! llm, model_id, prompt
    end

    private

    def create_llm_client(llm_api_key, model_id)
      # public_send dynamically invokes a public method on an object
      # Example: LLM.public_send(:openai, key: "xxx") is equivalent to LLM.openai(key: "xxx")
      # Unlike send, public_send cannot call private methods (safer)
      # Here, it calls one of :ollama, :openai, :anthropic, or :gemini based on llm_type
      # This eliminates the need for separate files for each LLM service

      if llm_api_key.nil? && LlmModelMap.ollama_model?(model_id)
        # Ollama doesn't require an API key (local service)
        LLM.public_send :ollama
      else
        llm_rb_method = llm_api_key.llm_rb_method
        LLM.public_send llm_rb_method, key: llm_api_key.encryptable_api_key.plain_api_key
      end
    end

    def find_model_id(llm, model_name)
      model = llm.models.all.find { it.id == model_name }
      raise ModelNotFoundError, model_name unless model

      model.id
    end

    def execute_chat!(llm, model_id, prompt)
      bot = LLM::Bot.new llm, model: model_id
      messages = bot.chat { it.user prompt }

      # messages[0] is the prompt so skip it, messages[1] represents the response message
      messages[1]&.content || ""
    end
  end
end
