module LlmRbFacade
  class << self
    def call!(model_id, prompt, llm_api_key: nil, tools: [], generation_params: {})
      # Validate arguments at the entry point
      validate_arguments! model_id, prompt, llm_api_key

      llm = create_llm_client llm_api_key, model_id

      if tools.any?
        execute_chat_with_tools! llm, model_id, prompt, tools, generation_params
      else
        execute_chat! llm, model_id, prompt, generation_params
      end
    end

    private

    def validate_arguments!(model_id, prompt, llm_api_key)
      raise ArgumentError, "model_id is required" if model_id.blank?
      raise ArgumentError, "prompt is required" if prompt.blank?

      # API key is required for non-Ollama models
      if llm_api_key.nil? && !LlmModelMap.ollama_model?(model_id)
        raise LlmApiKeyRequiredError, model_id
      end
    end

    def create_llm_client(llm_api_key, model_id)
      if LlmModelMap.ollama_model?(model_id)
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

    def execute_chat!(llm, model_id, prompt, generation_params)
      bot = LLM::Session.new llm, model: model_id, **generation_params
      messages = bot.chat prompt

      messages.choices[-1]&.content || ""
    end

    def execute_chat_with_tools!(llm, model_id, prompt, tools, generation_params)
      session = LLM::Session.new llm, model: model_id, tools: tools, **generation_params
      response = session.chat prompt

      # If LLM requested tool calls, execute them and send results back
      if session.functions.any?
        tool_results = session.functions.map(&:call)
        response = session.chat tool_results
      end

      build_response_with_tools(response, session)
    end

    def build_response_with_tools(response, session)
      content = response.choices[-1]&.content || ""
      tool_calls = session.extract_tool_calls

      if tool_calls.any?
        {
          message: content,
          tool_calls: tool_calls
        }
      else
        content
      end
    end
  end
end
