class LlmAdapter
  class << self
    def call(llm_api_key, model_name, prompt)
      llm = llm_api_key.build_llm
      model_id = find_model_id llm, model_name

      execute_chat llm, model_id, prompt
    end

    private

    def find_model_id(llm, model_name)
      model = llm.models.all.find { _1.id == model_name }
      raise ModelNotFoundError, model_name unless model

      model.id
    end

    def execute_chat(llm, model_id, prompt)
      bot = LLM::Bot.new llm, model: model_id
      messages = bot.chat { _1.user prompt }

      messages.map { _1.content }.join "\n"
    end
  end
end
