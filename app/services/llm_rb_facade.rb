require "base64"
require "tempfile"

module LlmRbFacade
  # The request no longer fits in the model's context window. Raised instead
  # of letting the provider's own reporting through: Ollama trims the oldest
  # messages to fit, then rejects its own trimmed array with "no user query
  # found in messages" — an error about a malformed request, for what is
  # really a sizing problem. That cost hours to diagnose on 2026-09-05.
  class ContextOverflowError < StandardError; end

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
      sink = TurnBudgetSink.new(sink, seconds: turn_budget_for(model_id)) unless sink.is_a?(TurnBudgetSink)
      generation_params = apply_provider_defaults(generation_params, llm_api_key)

      llm = create_llm_client llm_api_key, model_id
      native = native_server_tools(llm)

      payloads = coerce_file_payloads(image, images, document)
      begin
        stream_with_payloads(llm, native, payloads, model_id, prompt, sink,
                             tools:, generation_params:, on_tool_calls:, on_phase_change:,
                             messages:, endpoint:)
      ensure
        # Logged whatever happened — a turn that raised is exactly when you
        # want to know how far it got.
        Rails.logger.info(
          "[LlmStream] model=#{model_id} endpoint=#{endpoint} #{sink.stream_stats}"
        ) if sink.respond_to?(:stream_stats)
      end
    end

    # The body of stream!, split out so the logging above wraps every path.
    def stream_with_payloads(llm, native, payloads, model_id, prompt, sink,
                             tools:, generation_params:, on_tool_calls:, on_phase_change:,
                             messages:, endpoint:)
      with_file_payloads(payloads) do |contents|
        effective_prompt = contents.any? ? [ *contents, prompt ] : prompt

        # Route OpenAI reasoning models through the Responses API so
        # `response.reasoning_summary_text.delta` events can stream into
        # sink.thinking. Falls back to chat completions when the request
        # carries tools or an image — Responses support for those exists
        # but uses different wire shapes than we currently handle. Also
        # carries history too: prior user/assistant turns go in as `input:`
        # items, and the system prompt as `instructions:`, which is where the
        # Responses API takes each of them.
        #
        # History used to force the chat-completions fallback, because llm.rb
        # labels every string content `input_text` and the API rejects that
        # for assistant turns. config/initializers/openai_responses_history.rb
        # fixes the labelling, so multi-turn requests can stay on Responses
        # and keep streaming reasoning summaries past the first message.
        #
        # Note `prior_turns` excludes system messages — the chat client always
        # sends one ("respond with the body only"), so treating `messages` as
        # history made even a brand-new chat look multi-turn.
        prior_turns, instructions = split_conversation(messages)

        if endpoint == "responses" && tools.empty? && payloads.empty?
          stream_via_responses!(llm, model_id, effective_prompt, generation_params, sink,
                                instructions: instructions, history: prior_turns)
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
            chat_params, messages = apply_anthropic_system!(chat_params, messages, llm)
            session = LLM::Session.new llm, model: model_id, tools: native, **chat_params
            seed_session_messages!(session, messages)
            response = session.chat effective_prompt, stream: sink
            log_finish_diagnostics(response, "native")
            emit_length_cap_notice(response, sink)
            response.choices[-1]&.content || ""
          else
            chat_params, messages = apply_anthropic_system!(chat_params, messages, llm)
            session = LLM::Session.new llm, model: model_id, **chat_params
            seed_session_messages!(session, messages)
            # Controller already emitted "thinking" at the top. The model may
            # still think for a while before emitting content; the client flips
            # the indicator to "streaming" on the first content delta.
            response = with_context_overflow(model_id, context_window(chat_params)) do
              session.chat effective_prompt, stream: sink
            end
            emit_length_cap_notice(response, sink)
            response.choices[-1]&.content || ""
          end
        end
      end
    end

    # Stream a turn through OpenAI's Responses API. Used when the model's
    # catalog entry declares `endpoint: responses` (currently the GPT-5
    # family, to expose reasoning summaries). Restricted to the simple case
    # for now — no tools, no image.
    def stream_via_responses!(llm, model_id, prompt, params, sink, instructions: nil, history: [])
      # Prior turns ride along as `input:` items. llm.rb prepends them to the
      # current prompt (responses.rb: `[*params.delete(:input), Message.new(...)]`),
      # and openai_responses_history.rb makes sure assistant items are labelled
      # `output_text` rather than `input_text`.
      params = (params || {}).dup
      params[:instructions] = instructions if instructions.present?
      params[:input] = history.map { |turn| LLM::Message.new(field(turn, :role), field(turn, :content)) } if history.present?

      response = llm.responses.create(prompt, model: model_id, stream: sink, **params)
      response.respond_to?(:output_text) ? response.output_text.to_s : ""
    end

    private

    # Splits the client's role-tagged array into [prior_turns, instructions].
    #
    # System messages are not conversation history — they are the system
    # prompt, which the Responses API takes as a top-level `instructions:`
    # string rather than as an input item. Everything else (user/assistant)
    # is real history and is what disqualifies the Responses branch.
    def split_conversation(messages)
      return [ [], nil ] if messages.blank?

      system, turns = Array(messages).partition { |m| field(m, :role).to_s == "system" }
      instructions  = system.map { |m| field(m, :content).to_s }.reject(&:empty?).join("\n\n").presence
      [ turns, instructions ]
    end

    # Client messages arrive with symbol keys from the controller and string
    # keys from some callers; read either.
    def field(message, key)
      return nil unless message.respond_to?(:[])
      message[key] || message[key.to_s]
    end

    # Whether anything reached the client as *content*. Reasoning deltas go to
    # sink.thinking and do not count — a turn that streamed only reasoning is
    # exactly the case this exists to catch. Prefers the sink's own byte count
    # (what the user actually received) over the response body.
    def streamed_no_content?(sink, response)
      return sink.content_bytes.zero? if sink.respond_to?(:content_bytes)

      response.choices[-1]&.content.to_s.strip.empty?
    end

    # num_ctx as configured for this turn, or 0 when the provider has no such
    # notion (the hosted APIs manage their own window).
    def context_window(generation_params)
      opts = (generation_params || {})[:options] || (generation_params || {})["options"] || {}
      (opts[:num_ctx] || opts["num_ctx"]).to_i
    end

    def context_overflow_message(model_id, window, needed: nil)
      about = needed ? " (about #{needed} needed)" : ""
      "The conversation and tool results no longer fit in #{model_id}'s context " \
      "window of #{window} tokens#{about}. Select fewer tools, start a new chat, " \
      "or choose a model with a larger window."
    end

    # Translates the provider's confusing overflow reporting into our own.
    def with_context_overflow(model_id, window)
      yield
    rescue LLM::Error => e
      body   = (e.response.body if e.respond_to?(:response) && e.response.respond_to?(:body)).to_s
      detail = "#{e.message} #{body}"
      raise ContextOverflowError, context_overflow_message(model_id, window) if detail.match?(CONTEXT_OVERFLOW_SIGNATURE)

      raise
    end

    # Stops before a doomed turn rather than after it. Ollama reports the real
    # token count of the last prompt, so `used` is measured rather than
    # guessed; only the incoming tool results are estimated, since they have
    # not been tokenised yet.
    def guard_context!(model_id, window, response, tool_results)
      return if window.zero?
      return unless response.respond_to?(:prompt_eval_count)

      used = response.prompt_eval_count.to_i
      return if used.zero?

      incoming = (tool_results.sum { |r| r.to_s.length } / 4.0).ceil
      return if used + incoming < window

      raise ContextOverflowError, context_overflow_message(model_id, window, needed: used + incoming)
    end

    # Non-blocking: this turn can still succeed, but the next one probably
    # cannot, and saying so early beats a silent failure minutes later.
    def warn_context_pressure(model_id, window, response, sink)
      return if window.zero?
      return unless response.respond_to?(:prompt_eval_count)

      used = response.prompt_eval_count.to_i
      return if used.zero? || used < window * CONTEXT_PRESSURE_RATIO

      sink << "\n\n_(this conversation is using #{used} of #{model_id}'s #{window}-token " \
              "window — further tool results may not fit)_"
    end

    private :stream_with_payloads

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

    # Anthropic's API rejects role:"system" messages inline in `messages:`; the
    # system prompt must be passed via a top-level `system:` field. llm.rb 4.3.1
    # has no code that does this extraction — it forwards role as-is — so we do
    # it here for Anthropic only. Other providers (OpenAI, Ollama, Gemini) still
    # accept inline system messages, so their message arrays pass through
    # untouched. Returns [updated_chat_params, filtered_messages].
    def apply_anthropic_system!(chat_params, messages, llm)
      return [ chat_params, messages ] unless anthropic_provider?(llm)
      return [ chat_params, messages ] if messages.blank?

      system_msgs, other_msgs = Array(messages).partition do |m|
        h = m.respond_to?(:to_h) ? m.to_h : m
        (h[:role] || h["role"]).to_s == "system"
      end
      return [ chat_params, messages ] if system_msgs.empty?

      system_text = system_msgs.filter_map { |m|
        h = m.respond_to?(:to_h) ? m.to_h : m
        (h[:content] || h["content"]).to_s.presence
      }.join("\n\n")

      # Keep original chat_params if the user already set :system explicitly —
      # theirs wins; append ours below for context. This preserves whatever
      # persona-shaping the caller specifically configured.
      merged_system = [ chat_params[:system].to_s.presence, system_text.presence ].compact.join("\n\n")

      # If nothing to add (all system messages had blank content and no prior
      # :system was set), leave chat_params alone — but still filter the
      # blank system entries out of messages so they don't reach Anthropic.
      updated = merged_system.empty? ? chat_params : chat_params.merge(system: merged_system)
      [ updated, other_msgs ]
    end

    def anthropic_provider?(llm)
      llm && llm.class.name == "LLM::Anthropic"
    end

    # llm.rb's Anthropic provider hard-defaults max_tokens to 1024, which
    # truncates longer answers (stop_reason "max_tokens"). Other providers
    # don't cap this low and use a different param shape, so scope the
    # override to Anthropic and only when the user hasn't set their own.
    ANTHROPIC_DEFAULT_MAX_TOKENS = 8192

    # Wall-clock ceiling for one assistant turn, tool rounds included.
    # num_predict bounds tokens, not time: a local 36B at ~67 tok/s can spend
    # ten minutes on a 25k-token runaway and never trip a read timeout,
    # because bytes keep arriving. This is the backstop that does.
    TURN_BUDGET_SECONDS = Integer(ENV.fetch("LLM_TURN_BUDGET_SECONDS", 300))

    # Local models get a longer leash. 300s was set for the hosted providers,
    # where a slow turn also costs money; a local 36B is simply slower, and
    # legitimate work gets killed at 300s — qwen3.6:35b spent five minutes
    # genuinely reasoning through a constraint puzzle (11,628 reasoning
    # deltas) and was cut off mid-answer.
    #
    # This widens the window in which a runaway keeps going, which is the
    # thing the budget exists to stop: yy's incident was this same model
    # repeating one line 420 times. Wall-clock cannot tell those apart —
    # only repetition detection could, and that is the real fix. Until then
    # this trades a longer worst case for not truncating honest work.
    LOCAL_TURN_BUDGET_SECONDS = Integer(ENV.fetch("LLM_LOCAL_TURN_BUDGET_SECONDS", 900))

    def turn_budget_for(model_id)
      LlmModelMap.ollama_model?(model_id) ? LOCAL_TURN_BUDGET_SECONDS : TURN_BUDGET_SECONDS
    end

    def apply_provider_defaults(generation_params, llm_api_key)
      params = (generation_params || {}).to_h.symbolize_keys
      if llm_api_key&.llm_type == "anthropic"
        params[:max_tokens] = ANTHROPIC_DEFAULT_MAX_TOKENS if params[:max_tokens].blank?
        # Thinking config is per-model — Anthropic accepts different
        # `thinking.type` values across the catalog (adaptive on Sonnet
        # 4.6 / Opus 4.7 but not on Haiku 4.5). Declared per model in the
        # catalog's `defaults` column; merged in by the controller via
        # LlmModelMap.defaults_for.
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

        # Required when native server tools (Google Search grounding,
        # url_context) coexist with user-defined function tools (MCP).
        # Otherwise the API 400s with
        #   "Please enable tool_config.include_server_side_tool_invocations
        #   to use Built-in tools with Function calling."
        # Safe to set unconditionally — Gemini ignores the flag when only
        # one tool category is present.
        tool_cfg = (params[:tool_config] || {}).to_h.symbolize_keys
        tool_cfg[:include_server_side_tool_invocations] = true unless tool_cfg.key?(:include_server_side_tool_invocations)
        params[:tool_config] = tool_cfg
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
      host = OllamaEndpoint.host
      port = OllamaEndpoint.port
      opts[:host] = host if host.present?
      opts[:port] = port.to_i if port.present?
      opts
    end

    def find_model_id(llm, model_name)
      model = llm.models.all.find { it.id == model_name }
      raise ModelNotFoundError, model_name unless model

      model.id
    end

    def execute_chat!(llm, model_id, prompt, generation_params, messages: nil)
      generation_params, messages = apply_anthropic_system!(generation_params, messages, llm)
      bot = LLM::Session.new llm, model: model_id, **generation_params
      seed_session_messages!(bot, messages)
      messages_ret = bot.chat prompt

      messages_ret.choices[-1]&.content || ""
    end

    def execute_chat_with_tools!(llm, model_id, prompt, tools, generation_params, messages: nil)
      generation_params, messages = apply_anthropic_system!(generation_params, messages, llm)
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
    # Bumped from 5 to 10 (2026-07-22): Gemini + broker-aggregated tools
    # regularly need ≥6 rounds to converge (e.g. YouTube-transcript demo:
    # search → 5 parallel transcripts → synthesis). 10 still bounds runaway
    # loops; the fallback notice below fires if we hit the cap.
    MAX_TOOL_ITERATIONS = 10

    # Ollama's symptom of having trimmed the prompt to fit num_ctx.
    CONTEXT_OVERFLOW_SIGNATURE = /no user query found in messages/i

    # Warn once the prompt alone occupies this much of the window: there is
    # little room left for tool results or an answer.
    CONTEXT_PRESSURE_RATIO = 0.8

    EMPTY_ANSWER_NOTICE =
      "\n\n_(the model ended its turn without writing an answer. " \
      "Sending the message again often helps.)_"

    def stream_chat_with_tools!(llm, model_id, prompt, tools, generation_params, sink, on_tool_calls, on_phase_change, messages: nil)
      generation_params, messages = apply_anthropic_system!(generation_params, messages, llm)
      window  = context_window(generation_params)
      session = LLM::Session.new llm, model: model_id, tools: tools, **generation_params
      seed_session_messages!(session, messages)
      response = with_context_overflow(model_id, window) do
        session.chat prompt, stream: false # turn 1: explicitly non-streamed
      end
      warn_context_pressure(model_id, window, response, sink)
      rehydrate_anthropic_tool_response!(session, response) if session.functions.empty?
      Rails.logger.info "[LlmRbFacade] turn=1 functions.any?=#{session.functions.any?} " \
                        "content_len=#{response.choices[-1]&.content.to_s.length}"

      iterations = 0
      while session.functions.any? && iterations < MAX_TOOL_ITERATIONS
        # Snapshot the call metadata BEFORE execution — session.extract_tool_calls
        # walks the assistant messages that will still be there after execution,
        # but capturing now keeps the pairing with tool_results 1:1 obvious.
        tool_call_meta = session.extract_tool_calls
        tool_results   = session.functions.map(&:call)
        emit_tool_errors_to_sink(tool_results, sink)
        # Fire on_tool_calls AFTER execution with results attached, so the
        # chat UI can show what each tool returned (essential for debugging).
        on_tool_calls&.call(zip_tool_calls_with_results(tool_call_meta, tool_results))
        # Each iteration may think again before emitting content — re-signal
        # so the role label flips back to "thinking" between turns.
        on_phase_change&.call("thinking")
        # Refuse a round that cannot fit rather than spending minutes of
        # prefill to have the provider reject it.
        guard_context!(model_id, window, response, tool_results)
        response = with_context_overflow(model_id, window) do
          session.chat tool_results, stream: sink # streamed
        end
        rehydrate_anthropic_tool_response!(session, response) if session.functions.empty?
        iterations += 1
        Rails.logger.info "[LlmRbFacade] tool_iter=#{iterations} " \
                          "functions.any?=#{session.functions.any?} " \
                          "content_len=#{response.choices[-1]&.content.to_s.length}"
      end

      if iterations.zero?
        # Turn 1 had no tool calls — emit its content as one chunk.
        text = response.choices[-1]&.content || ""
        text.empty? ? sink << EMPTY_ANSWER_NOTICE : sink << text
      elsif session.functions.any?
        # Cap hit while the model still wanted to call more tools. Tell the
        # user instead of leaving the bubble silently empty.
        sink << "\n\n_(stopped after #{MAX_TOOL_ITERATIONS} tool rounds without a final answer)_"
      elsif streamed_no_content?(sink, response)
        # The loop finished cleanly and the model still wrote nothing. A
        # thinking model can end its turn this way: qwen3.8 read a tool's
        # usage guide, spent 2,255 characters reasoning about it, then
        # stopped without answering and without calling anything else. The
        # bubble was empty with no explanation, which reads as a failure.
        sink << EMPTY_ANSWER_NOTICE
      end
      emit_length_cap_notice(response, sink)

      build_response_with_tools(response, session)
    end

    # Ollama stops at `options.num_predict` and reports `done_reason: "length"`.
    # Left alone that reads as an answer trailing off mid-sentence, so name it
    # — same contract as the MAX_TOOL_ITERATIONS notice above. Providers that
    # do not report the field (everything but Ollama today) no-op here.
    def emit_length_cap_notice(response, sink)
      return if response.nil?
      return unless response.respond_to?(:done_reason)
      return unless response.done_reason.to_s == "length"
      sink << "\n\n_(truncated at the output limit — narrow the question, " \
              "or raise `options.num_predict`)_"
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

    # Max characters of a tool result to include in the tool_calls event.
    # Chosen to fit comfortably in a collapsed <details> block without
    # bloating the persisted assistant message. Users can hit the tool
    # directly via the browsable URL (see MCP tool responses) to see full
    # output.
    TOOL_RESULT_TRUNCATE_LEN = 1500

    # Pair each { id:, name:, arguments: } from extract_tool_calls with the
    # matching Return value from session.functions.map(&:call). Match by id
    # when available (safest across providers that batch multiple parallel
    # tool calls); fall back to positional pairing for providers that don't
    # populate id.
    def zip_tool_calls_with_results(call_meta, tool_results)
      results_by_id = tool_results.each_with_object({}) do |r, h|
        id = r.respond_to?(:id) ? r.id : nil
        h[id] = r if id
      end

      call_meta.each_with_index.map do |call, i|
        result = results_by_id[call[:id]] || tool_results[i]
        call.merge(result: extract_tool_result_text(result&.value))
      end
    end

    # Reduce an arbitrary tool result to a display-friendly string. MCP tools
    # return `{content: [{type: "text", text: "..."}, ...]}` — concat those
    # text parts. Anything else gets JSON-serialized. Then truncate.
    def extract_tool_result_text(value)
      raw =
        if value.is_a?(Hash) && value["content"].is_a?(Array)
          value["content"].filter_map { |c| c.is_a?(Hash) ? c["text"] : nil }.join("\n").presence ||
            value.to_json
        elsif value.nil?
          ""
        elsif value.is_a?(String)
          value
        else
          value.to_json rescue value.to_s
        end
      truncate_for_display(raw)
    end

    def truncate_for_display(str)
      return str.to_s if str.to_s.length <= TOOL_RESULT_TRUNCATE_LEN
      "#{str[0, TOOL_RESULT_TRUNCATE_LEN]}… (truncated, #{str.length - TOOL_RESULT_TRUNCATE_LEN} more chars)"
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
