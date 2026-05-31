require "base64"
require "tempfile"

module LlmRbFacade
  class << self
    def call!(model_id, prompt, llm_api_key: nil, tools: [], generation_params: {}, image: nil)
      # Validate arguments at the entry point
      validate_arguments! model_id, prompt, llm_api_key
      generation_params = apply_provider_defaults(generation_params, llm_api_key)

      llm = create_llm_client llm_api_key, model_id
      all_tools = tools + native_server_tools(llm)

      with_image_payload(image) do |content|
        effective_prompt = content ? [ content, prompt ] : prompt
        if all_tools.any?
          execute_chat_with_tools! llm, model_id, effective_prompt, all_tools, generation_params
        else
          execute_chat! llm, model_id, effective_prompt, generation_params
        end
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
    def stream!(model_id, prompt, sink:, llm_api_key: nil, tools: [], generation_params: {}, on_tool_calls: nil, on_phase_change: nil, image: nil)
      validate_arguments! model_id, prompt, llm_api_key
      generation_params = apply_provider_defaults(generation_params, llm_api_key)

      llm = create_llm_client llm_api_key, model_id
      native = native_server_tools(llm)

      with_image_payload(image) do |content|
        effective_prompt = content ? [ content, prompt ] : prompt

        if tools.any?
          # MCP function tools present — needs the turn1/turn2 execution loop.
          # Native server tools ride along in the same array; the gem's
          # adapt_tools splits ServerTools from Functions for the request.
          stream_chat_with_tools! llm, model_id, effective_prompt, tools + native, generation_params, sink, on_tool_calls, on_phase_change
        elsif native.any?
          # Native-only (e.g. Gemini grounding / url_context): provider-side
          # tools, no function round-trip — stream the grounded answer directly.
          session = LLM::Session.new llm, model: model_id, tools: native, **generation_params
          response = session.chat effective_prompt, stream: sink
          log_finish_diagnostics(response, "native")
          response.choices[-1]&.content || ""
        else
          session = LLM::Session.new llm, model: model_id, **generation_params
          # Controller already emitted "thinking" at the top. The model may
          # still think for a while before emitting content; the client flips
          # the indicator to "streaming" on the first content delta.
          response = session.chat effective_prompt, stream: sink
          response.choices[-1]&.content || ""
        end
      end
    end

    private

    # llm.rb's Anthropic provider hard-defaults max_tokens to 1024, which
    # truncates longer answers (stop_reason "max_tokens"). Other providers
    # don't cap this low and use a different param shape, so scope the
    # override to Anthropic and only when the user hasn't set their own.
    ANTHROPIC_DEFAULT_MAX_TOKENS = 8192

    def apply_provider_defaults(generation_params, llm_api_key)
      params = (generation_params || {}).to_h.symbolize_keys
      if llm_api_key&.llm_type == "anthropic" && params[:max_tokens].blank?
        params[:max_tokens] = ANTHROPIC_DEFAULT_MAX_TOKENS
      end
      params
    end

    # Build an LLM::Object(:local_file) from a transport payload `{mime:, data_b64:}`
    # by writing the bytes to a Tempfile and wrapping with LLM::File. Each provider's
    # adapt_local_file consumes only the standard LLM::File interface (mime_type,
    # to_b64, image?, basename, to_data_uri), so this works uniformly across
    # OpenAI / Anthropic / Gemini / Ollama. Yields content (or nil), cleans up.
    def with_image_payload(image)
      return yield(nil) if image.blank?

      mime = (image[:mime] || image["mime"]).to_s
      data_b64 = (image[:data_b64] || image["data_b64"]).to_s
      return yield(nil) if mime.empty? || data_b64.empty?

      ext = mime.split("/").last.to_s
      ext = ext.sub(/[;+].*$/, "") # strip params like "jpeg;charset=..."
      ext = "bin" if ext.empty?
      tmp = Tempfile.new([ "llm_meta_img_", ".#{ext}" ], binmode: true)
      tmp.write(Base64.decode64(data_b64))
      tmp.close

      file = LLM::File.new(tmp.path)
      content = LLM::Object.new(kind: :local_file, value: file)
      yield(content)
    ensure
      tmp&.close
      tmp&.unlink
    end

    def validate_arguments!(model_id, prompt, llm_api_key)
      raise ArgumentError, "model_id is required" if model_id.blank?
      raise ArgumentError, "prompt is required" if prompt.blank?

      # API key is required for non-Ollama models
      if llm_api_key.nil? && !LlmModelMap.ollama_model?(model_id)
        raise LlmApiKeyRequiredError, model_id
      end
    end

    # Native (provider-executed) server tools to attach implicitly based on
    # the selected model's provider. Picking a Gemini model is itself the
    # signal that grounding is wanted — no separate toggle. These are
    # LLM::ServerTool objects; llm.rb merges them with MCP functions.
    NATIVE_GEMINI_TOOLS = %i[google_search url_context].freeze

    # Diagnostic: capture why generation stopped. finishReason "MAX_TOKENS"
    # means the output cap was hit (truncation); "STOP" with short content
    # points at a transport/stream issue instead.
    def log_finish_diagnostics(response, label)
      body = response.body rescue nil
      cand = (body&.candidates&.first rescue nil)
      finish = (cand&.finishReason rescue nil)
      total = (body&.usageMetadata&.totalTokenCount rescue nil)
      len = (response.choices[-1]&.content&.length rescue nil)
      Rails.logger.info "[LlmRbFacade] #{label} finishReason=#{finish.inspect} " \
                        "total_tokens=#{total.inspect} content_len=#{len.inspect}"
    rescue StandardError => e
      Rails.logger.warn "[LlmRbFacade] diagnostics failed: #{e.class}: #{e.message}"
    end

    def native_server_tools(llm)
      return [] unless llm.class.name == "LLM::Gemini"
      return [] unless llm.respond_to?(:server_tools)

      llm.server_tools.values_at(*NATIVE_GEMINI_TOOLS).compact
    rescue StandardError => e
      Rails.logger.warn "[LlmRbFacade] native tool resolution failed: #{e.class}: #{e.message}"
      []
    end

    # llm.rb's Provider#initialize defaults read timeout to 60s (per-read).
    # That's too short for large local models (e.g. qwen3.6:35b) with image
    # input, where the first-token wait alone can exceed it. Bump generously.
    PROVIDER_READ_TIMEOUT_SECONDS = 300

    def create_llm_client(llm_api_key, model_id)
      if LlmModelMap.ollama_model?(model_id)
        LLM.ollama(**ollama_options)
      else
        llm_rb_method = llm_api_key.llm_rb_method
        LLM.public_send llm_rb_method,
          key: llm_api_key.encryptable_api_key.plain_api_key,
          timeout: PROVIDER_READ_TIMEOUT_SECONDS
      end
    end

    def ollama_options
      opts = { timeout: PROVIDER_READ_TIMEOUT_SECONDS }
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

    # Maximum tool-call rounds. Small models (notably qwen3.6:35b-fast) will often
    # chain another tool call instead of synthesizing text in turn 2, leaving
    # the bubble empty. Loop until the model emits text or we hit the cap.
    MAX_TOOL_ITERATIONS = 5

    def stream_chat_with_tools!(llm, model_id, prompt, tools, generation_params, sink, on_tool_calls, on_phase_change)
      session = LLM::Session.new llm, model: model_id, tools: tools, **generation_params
      response = session.chat prompt, stream: false # turn 1: explicitly non-streamed
      rehydrate_anthropic_tool_response!(session, response) if session.functions.empty?
      Rails.logger.info "[LlmRbFacade] turn=1 functions.any?=#{session.functions.any?} " \
                        "content_len=#{response.choices[-1]&.content.to_s.length}"

      iterations = 0
      while session.functions.any? && iterations < MAX_TOOL_ITERATIONS
        on_tool_calls&.call(session.extract_tool_calls)
        tool_results = session.functions.map(&:call)
        emit_tool_errors_to_sink(tool_results, sink)
        # Each iteration may think again before emitting content — re-signal
        # so the role label flips back to "thinking" between turns.
        on_phase_change&.call("thinking")
        response = session.chat tool_results, stream: sink # streamed
        rehydrate_anthropic_tool_response!(session, response) if session.functions.empty?
        iterations += 1
        Rails.logger.info "[LlmRbFacade] tool_iter=#{iterations} " \
                          "functions.any?=#{session.functions.any?} " \
                          "content_len=#{response.choices[-1]&.content.to_s.length}"
      end

      if iterations.zero?
        # Turn 1 had no tool calls — emit its content as one chunk.
        text = response.choices[-1]&.content || ""
        sink << text unless text.empty?
      elsif session.functions.any?
        # Cap hit while the model still wanted to call more tools. Tell the
        # user instead of leaving the bubble silently empty.
        sink << "\n\n_(stopped after #{MAX_TOOL_ITERATIONS} tool rounds without a final answer)_"
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
