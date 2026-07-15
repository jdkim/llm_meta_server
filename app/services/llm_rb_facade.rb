require "base64"
require "tempfile"

module LlmRbFacade
  class << self
    def call!(model_id, prompt, llm_api_key: nil, tools: [], generation_params: {}, image: nil, images: nil, document: nil, messages: nil)
      # Validate arguments at the entry point
      validate_arguments! model_id, prompt, llm_api_key
      generation_params = apply_provider_defaults(generation_params, llm_api_key)

      llm = create_llm_client llm_api_key, model_id
      all_tools = tools + native_server_tools(llm)

      with_file_payloads(coerce_file_payloads(image, images, document)) do |contents|
        effective_prompt = contents.any? ? [ *contents, prompt ] : prompt
        if all_tools.any?
          execute_chat_with_tools! llm, model_id, effective_prompt, all_tools, generation_params, messages: messages
        else
          execute_chat! llm, model_id, effective_prompt, generation_params, messages: messages
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
    def stream!(model_id, prompt, sink:, llm_api_key: nil, tools: [], generation_params: {}, on_tool_calls: nil, on_phase_change: nil, image: nil, images: nil, document: nil, messages: nil, endpoint: "chat_completions")
      validate_arguments! model_id, prompt, llm_api_key
      generation_params = apply_provider_defaults(generation_params, llm_api_key)

      llm = create_llm_client llm_api_key, model_id
      native = native_server_tools(llm)

      payloads = coerce_file_payloads(image, images, document)
      with_file_payloads(payloads) do |contents|
        effective_prompt = contents.any? ? [ *contents, prompt ] : prompt

        # Route OpenAI reasoning models through the Responses API so
        # `response.reasoning_summary_text.delta` events can stream into
        # sink.thinking. Falls back to chat completions when the request
        # carries tools or an image — Responses support for those exists
        # but uses different wire shapes than we currently handle. Also
        # skips Responses when `messages:` is provided: llm.rb's Responses
        # request adapter labels every string content as `input_text`,
        # which the API rejects for assistant history (needs `output_text`).
        # Correctness > reasoning summaries — multi-turn gpt-5 falls back
        # to chat completions.
        if endpoint == "responses" && tools.empty? && payloads.empty? && messages.blank?
          stream_via_responses!(llm, model_id, effective_prompt, generation_params, sink)
        else
          # Every other branch uses chat completions. If the model catalog
          # entry declared `endpoint: responses`, its defaults (e.g. `reasoning:`)
          # may include params that only the Responses API accepts. Strip
          # them so chat completions doesn't reject the request.
          chat_params = strip_responses_only_params(generation_params, endpoint)

          if tools.any?
            # MCP function tools present — needs the turn1/turn2 execution loop.
            # Native server tools ride along in the same array; the gem's
            # adapt_tools splits ServerTools from Functions for the request.
            stream_chat_with_tools! llm, model_id, effective_prompt, tools + native, chat_params, sink, on_tool_calls, on_phase_change, messages: messages
          elsif native.any?
            # Native-only (e.g. Gemini grounding / url_context): provider-side
            # tools, no function round-trip — stream the grounded answer directly.
            session = LLM::Session.new llm, model: model_id, tools: native, **chat_params
            seed_session_messages!(session, messages)
            response = session.chat effective_prompt, stream: sink
            log_finish_diagnostics(response, "native")
            response.choices[-1]&.content || ""
          else
            session = LLM::Session.new llm, model: model_id, **chat_params
            seed_session_messages!(session, messages)
            # Controller already emitted "thinking" at the top. The model may
            # still think for a while before emitting content; the client flips
            # the indicator to "streaming" on the first content delta.
            response = session.chat effective_prompt, stream: sink
            response.choices[-1]&.content || ""
          end
        end
      end
    end

    # Stream a turn through OpenAI's Responses API. Used when the model's
    # catalog entry declares `endpoint: responses` (currently the GPT-5
    # family, to expose reasoning summaries). Restricted to the simple case
    # for now — no tools, no image.
    def stream_via_responses!(llm, model_id, prompt, params, sink)
      # Multi-turn history is intentionally NOT forwarded here — llm.rb's
      # Responses request adapter labels every string content as `input_text`,
      # which the API rejects for assistant messages. The caller routes
      # requests with `messages:` through chat completions instead.
      response = llm.responses.create(prompt, model: model_id, stream: sink, **params)
      response.respond_to?(:output_text) ? response.output_text.to_s : ""
    end

    private

    # Params that only OpenAI's Responses endpoint accepts. When a model
    # declared `endpoint: responses` but the request is routed through
    # chat completions (e.g. multi-turn `messages:`, tools, or attachments
    # present), strip these so the chat completions API doesn't 400 on
    # "Unknown parameter".
    RESPONSES_ONLY_PARAM_KEYS = %i[reasoning].freeze

    def strip_responses_only_params(params, endpoint)
      return params unless endpoint == "responses"
      return params if params.nil? || params.empty?
      params.reject { |k, _| RESPONSES_ONLY_PARAM_KEYS.include?(k.to_sym) }
    end

    # ─── Multi-turn history support ─────────────────────────────────────
    # Pre-seed an LLM::Session's internal @messages buffer with prior
    # turns so the current `session.chat(prompt)` call sees them as
    # role-tagged conversation history — instead of the historical
    # "concatenate everything into one user string" packaging that made
    # models re-execute the previous prompt's task instead of the new one.
    def seed_session_messages!(session, messages)
      objs = messages_to_llm_objects(messages)
      return if objs.empty?
      session.messages.concat objs
    end

    # Convert a wire-shape `[{role: "user"|"assistant"|"system", content: "..."}]`
    # array into a list of `LLM::Message` objects. Nils, missing keys, and
    # blank content are dropped defensively so a malformed history doesn't
    # blow up the whole turn.
    def messages_to_llm_objects(messages)
      return [] if messages.nil? || (messages.respond_to?(:empty?) && messages.empty?)
      Array(messages).filter_map do |m|
        h = m.respond_to?(:to_h) ? m.to_h : m
        role    = (h[:role]    || h["role"]).to_s
        content = (h[:content] || h["content"]).to_s
        next if role.empty? || content.empty?
        LLM::Message.new(role, content)
      end
    end

    # llm.rb's Anthropic provider hard-defaults max_tokens to 1024, which
    # truncates longer answers (stop_reason "max_tokens"). Other providers
    # don't cap this low and use a different param shape, so scope the
    # override to Anthropic and only when the user hasn't set their own.
    ANTHROPIC_DEFAULT_MAX_TOKENS = 8192

    def apply_provider_defaults(generation_params, llm_api_key)
      params = (generation_params || {}).to_h.symbolize_keys
      if llm_api_key&.llm_type == "anthropic"
        params[:max_tokens] = ANTHROPIC_DEFAULT_MAX_TOKENS if params[:max_tokens].blank?
        # Thinking config is per-model — Anthropic accepts different
        # `thinking.type` values across the catalog (adaptive on Sonnet
        # 4.6 / Opus 4.7 but not on Haiku 4.5). Declared in
        # config/llm_models.yml under each model's `defaults:` block;
        # merged in by the controller via LlmModelMap.defaults_for.
      end
      if llm_api_key&.llm_type == "google"
        # Gemini's thinking-capable models think internally by default but
        # don't expose those tokens unless the request opts in. Inject
        # generationConfig.thinkingConfig.includeThoughts: true (without
        # clobbering anything else the user set under generationConfig).
        gc = (params[:generationConfig] || {}).to_h.symbolize_keys
        tc = (gc[:thinkingConfig] || {}).to_h.symbolize_keys
        tc[:includeThoughts] = true unless tc.key?(:includeThoughts)
        gc[:thinkingConfig] = tc
        params[:generationConfig] = gc
      end
      params
    end

    # Normalize the legacy `image:` (single), `images:` (array), and
    # `document:` (single) kwargs into a single chronologically-ordered
    # array of `{mime:, data_b64:}` payloads. The current turn's image is
    # by convention the last element of `images:`; a document (when present)
    # is appended after the images.
    def coerce_file_payloads(image, images, document)
      list = images.is_a?(Array) ? images.compact : []
      list = [ image ] if list.empty? && image.present?
      list << document if document.present?
      list.reject { |p| p.blank? }
    end

    # Build an array of LLM::Object(:local_file) entries — one per payload —
    # by writing each blob to its own Tempfile and wrapping with LLM::File.
    # Each provider's adapt_local_file consumes only the standard LLM::File
    # interface (mime_type, to_b64, image?, pdf?, basename, to_data_uri), so
    # this works uniformly across OpenAI / Anthropic / Gemini / Ollama for
    # both images and PDFs — llm.rb's provider adapters route by MIME.
    # Yields the list (possibly empty) and cleans up every Tempfile, even
    # on raise.
    def with_file_payloads(payloads)
      return yield([]) if payloads.blank?

      tmps = []
      contents = []
      payloads.each do |payload|
        mime = (payload[:mime] || payload["mime"]).to_s
        data_b64 = (payload[:data_b64] || payload["data_b64"]).to_s
        next if mime.empty? || data_b64.empty?

        ext = mime.split("/").last.to_s
        ext = ext.sub(/[;+].*$/, "")
        ext = "bin" if ext.empty?
        tmp = Tempfile.new([ "llm_meta_file_", ".#{ext}" ], binmode: true)
        tmp.write(Base64.decode64(data_b64))
        tmp.close
        tmps << tmp

        file = LLM::File.new(tmp.path)
        contents << LLM::Object.new(kind: :local_file, value: file)
      end

      yield(contents)
    ensure
      tmps&.each { |t| t.close rescue nil; t.unlink rescue nil }
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
    # the selected model's provider. Picking a Gemini or Anthropic model is
    # itself the signal that grounding is wanted — no separate toggle. These
    # are LLM::ServerTool objects; llm.rb merges them with MCP functions.
    #
    # OpenAI's `web_search` is intentionally omitted here: llm.rb's OpenAI
    # provider only exposes it via the Responses API, and the facade's
    # `stream_via_responses!` branch currently rejects any request carrying
    # tools. Wiring it needs a separate Responses-with-tools branch.
    NATIVE_GEMINI_TOOLS    = %i[google_search url_context].freeze
    NATIVE_ANTHROPIC_TOOLS = %i[web_search].freeze

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
      return [] unless llm.respond_to?(:server_tools)

      keys = case llm.class.name
      when "LLM::Gemini"    then NATIVE_GEMINI_TOOLS
      when "LLM::Anthropic" then NATIVE_ANTHROPIC_TOOLS
      else                       return []
      end
      llm.server_tools.values_at(*keys).compact
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

    def execute_chat!(llm, model_id, prompt, generation_params, messages: nil)
      bot = LLM::Session.new llm, model: model_id, **generation_params
      seed_session_messages!(bot, messages)
      messages_ret = bot.chat prompt

      messages_ret.choices[-1]&.content || ""
    end

    def execute_chat_with_tools!(llm, model_id, prompt, tools, generation_params, messages: nil)
      session = LLM::Session.new llm, model: model_id, tools: tools, **generation_params
      seed_session_messages!(session, messages)
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

    def stream_chat_with_tools!(llm, model_id, prompt, tools, generation_params, sink, on_tool_calls, on_phase_change, messages: nil)
      session = LLM::Session.new llm, model: model_id, tools: tools, **generation_params
      seed_session_messages!(session, messages)
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
