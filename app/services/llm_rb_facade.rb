module LlmRbFacade
  class << self
    def call!(model_id, prompt, llm_api_key: nil, tools: [])
      # Validate arguments at the entry point
      validate_arguments! model_id, prompt, llm_api_key

      llm = create_llm_client llm_api_key, model_id

      if tools.any?
        execute_chat_with_tools! llm, model_id, prompt, tools
      else
        execute_chat! llm, model_id, prompt
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

    def execute_chat!(llm, model_id, prompt)
      bot = LLM::Session.new llm, model: model_id
      messages = bot.chat prompt

      messages.choices[-1]&.content || ""
    end

    def execute_chat_with_tools!(llm, model_id, prompt, tools)
      session = LLM::Session.new llm, model: model_id, tools: tools
      response = session.chat prompt

      # If LLM requested tool calls, execute them and send results back
      if session.functions.any?
        tool_results = session.functions.map(&:call)
        response = session.chat tool_results
      end

      build_tool_response(response, session)
    end

    def build_tool_response(response, session)
      content = response.choices[-1]&.content || ""
      tool_calls = extract_tool_calls(session)

      if tool_calls.any?
        {
          message: content,
          tool_calls: tool_calls
        }
      else
        content
      end
    end

    def extract_tool_calls(session)
      session.messages
        .select { it.respond_to?(:assistant?) && it.assistant? }
        .select { it.respond_to?(:tool_call?) && it.tool_call? }
        .flat_map { it.to_h[:tools] || [] }
        .map { normalize_tool_call(it) }
    end

    def normalize_tool_call(tc)
      if tc.respond_to?(:id)
        { id: tc.id, name: tc.name, arguments: tc.arguments }
      else
        { id: tc[:id] || tc["id"], name: tc[:name] || tc["name"], arguments: tc[:arguments] || tc["arguments"] }
      end
    end
  end
end
