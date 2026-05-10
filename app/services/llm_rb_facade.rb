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

    # Streaming variant: deltas are pushed to `sink` (any object responding to <<)
    # as they arrive from the provider.
    #
    # When `tools` is non-empty, turn 1 (tool selection) runs synchronously and
    # is NOT streamed. If the LLM requests tool calls, `on_tool_calls` (if given)
    # is invoked with the array before tools execute. Turn 2 (the follow-up
    # response after tool results) IS streamed to `sink`.
    #
    # Returns the assembled string when no tools were called, or
    # { message:, tool_calls: } when tools were called — same shape as `call!`.
    def stream!(model_id, prompt, sink:, llm_api_key: nil, tools: [], generation_params: {}, on_tool_calls: nil)
      validate_arguments! model_id, prompt, llm_api_key

      llm = create_llm_client llm_api_key, model_id

      if tools.any?
        stream_chat_with_tools! llm, model_id, prompt, tools, generation_params, sink, on_tool_calls
      else
        session = LLM::Session.new llm, model: model_id, **generation_params
        response = session.chat prompt, stream: sink
        response.choices[-1]&.content || ""
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
        LLM.ollama(**ollama_options)
      else
        llm_rb_method = llm_api_key.llm_rb_method
        LLM.public_send llm_rb_method, key: llm_api_key.encryptable_api_key.plain_api_key
      end
    end

    def ollama_options
      opts = {}
      opts[:host] = ENV["OLLAMA_HOST"] if ENV["OLLAMA_HOST"].present?
      opts[:port] = ENV["OLLAMA_PORT"].to_i if ENV["OLLAMA_PORT"].present?
      opts
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
      rehydrate_anthropic_tool_response!(session, response) if session.functions.empty?
      Rails.logger.info "[LlmRbFacade] functions.any?=#{session.functions.any?} " \
                        "first_content=#{response.choices[-1]&.content.inspect} " \
                        "extract_tool_calls=#{session.extract_tool_calls.inspect}"

      # If LLM requested tool calls, execute them and send results back
      if session.functions.any?
        tool_results = session.functions.map(&:call)
        response = session.chat tool_results
        Rails.logger.info "[LlmRbFacade] after_tools_content=#{response.choices[-1]&.content.inspect}"
      end

      build_response_with_tools(response, session)
    end

    def stream_chat_with_tools!(llm, model_id, prompt, tools, generation_params, sink, on_tool_calls)
      session = LLM::Session.new llm, model: model_id, tools: tools, **generation_params
      response = session.chat prompt # turn 1: not streamed (tool selection)
      rehydrate_anthropic_tool_response!(session, response) if session.functions.empty?

      if session.functions.any?
        on_tool_calls&.call(session.extract_tool_calls)
        tool_results = session.functions.map(&:call)
        emit_tool_errors_to_sink(tool_results, sink)
        response = session.chat tool_results, stream: sink # turn 2: streamed
      else
        text = response.choices[-1]&.content || ""
        sink << text unless text.empty?
      end

      build_response_with_tools(response, session)
    end

    # If any tool returned an MCP-style {"isError": true, "content": [...]} payload,
    # write a brief explanation through the sink before turn 2 streams. Some
    # models (notably Gemini) will silently emit nothing after a tool error,
    # so this guarantees the user always sees what went wrong.
    def emit_tool_errors_to_sink(tool_results, sink)
      errored = tool_results.select { |r| r.value.is_a?(Hash) && r.value["isError"] }
      return if errored.empty?

      lines = errored.map do |r|
        msg = r.value.dig("content", 0, "text").to_s.strip
        msg = "(no error message)" if msg.empty?
        "**Tool `#{r.name}` failed:** #{msg}"
      end
      sink << lines.join("\n\n") + "\n\n"
    end

    # Anthropic's response_adapter only builds `choices` from text parts of the
    # response, so a tool-only Claude response yields an empty choices array and
    # Session#talk pushes a nil into the messages buffer. Reconstruct the
    # missing assistant message from response.body.content so session.functions
    # / session.extract_tool_calls work uniformly with OpenAI's flow.
    def rehydrate_anthropic_tool_response!(session, response)
      body = response.body rescue nil
      return unless body.respond_to?(:content)
      parts = body.content
      return unless parts.respond_to?(:select)

      tool_uses = parts.select { |p| (p.respond_to?(:[]) && p["type"] == "tool_use") || (p.respond_to?(:type) && p.type == "tool_use") }
      return if tool_uses.empty?

      tool_calls = tool_uses.map do |t|
        { id: extract_field(t, "id"), name: extract_field(t, "name"), arguments: extract_field(t, "input") }
      end

      msg = LLM::Message.new(
        "assistant",
        nil,
        response: response,
        tool_calls: tool_calls,
        original_tool_calls: tool_uses
      )
      # Session#talk just pushed `nil` as the placeholder for choices[-1].
      # Evict it (and any other trailing nils) so downstream request adapters
      # iterating messages don't NoMethodError on `.tool_call?` etc.
      raw = session.messages.instance_variable_get(:@messages)
      raw.pop while raw && raw.last.nil?
      session.messages << msg
    end

    def extract_field(obj, key)
      if obj.respond_to?(:[])
        v = obj[key]
        return v unless v.nil?
        return obj[key.to_sym]
      end
      obj.public_send(key) if obj.respond_to?(key)
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
