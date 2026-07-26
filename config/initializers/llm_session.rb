module LLM
  # Override LLM::Message#functions to handle history-replay for the client-
  # orchestrated flow (Api::SingleLlmCallsController). Upstream:
  #
  #   def functions
  #     @functions ||= tool_calls.map do |fn|
  #       function = available_tools.find { _1.name.to_s == fn["name"] }.dup
  #       function.tap { _1.id = fn.id }
  #       function.tap { _1.arguments = fn.arguments }
  #     end
  #   end
  #
  # `available_tools` is `response&.__tools__ || []`. For assistant messages
  # we RECONSTRUCT from client-sent history via `messages_to_llm_objects`,
  # there's no wrapping response — `available_tools` is `[]`, `.find` returns
  # nil, `.dup` returns nil, `.tap { _1.id = ... }` raises. Building the
  # LLM::Function object directly from the tool_call data (and marking it as
  # already-called so Session#functions doesn't re-dispatch it) makes replay
  # work without perturbing the hub-orchestrated path (where available_tools
  # IS populated and the `find` succeeds).
  class Message
    def functions
      @functions ||= tool_calls.map do |fn|
        matched = available_tools.find { _1.name.to_s == fn["name"] }
        if matched
          # Hub-orchestrated flow: fresh response → available_tools populated →
          # normal path. Function remains PENDING so the hub can dispatch it.
          matched.dup
            .tap { _1.id = fn["id"] || fn.id }
            .tap { _1.arguments = fn["arguments"] || fn.arguments }
        else
          # Client-orchestrated flow: reconstructed history message has no
          # wrapping response → available_tools is []. Build directly, and
          # mark @called so Session#functions#select(&:pending?) skips it —
          # the client already dispatched.
          LLM::Function.new(fn["name"])
            .tap { _1.id = fn["id"] || fn.id }
            .tap { _1.arguments = fn["arguments"] || fn.arguments }
            .tap { _1.instance_variable_set(:@called, true) }
        end
      end
    end
  end

  class Session
    def extract_tool_calls
      messages
        .select { it.respond_to?(:assistant?) && it.assistant? }
        .select { it.respond_to?(:tool_call?) && it.tool_call? }
        .flat_map { it.to_h[:tools] || [] }
        .map { normalize_tool_call(it) }
    end

    # Override llm.rb's Session#functions to tolerate nil entries in the
    # messages buffer. Anthropic's adapter filters `choices` for text-only
    # parts, so a tool-only Claude response yields an empty `choices` array
    # and Session#talk ends up pushing `nil` via `@messages.concat [res.choices[-1]]`.
    # The stock `.select(&:assistant?)` then raises NoMethodError on those nils.
    def functions
      @messages
        .select { it.respond_to?(:assistant?) && it.assistant? }
        .flat_map do |msg|
          fns = msg.functions.select(&:pending?)
          fns.each do |fn|
            fn.tracer = tracer
            fn.model  = msg.model
          end
          fns
        end
    end

    private

    def normalize_tool_call(tc)
      raw_args = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc["arguments"])
      args = coerce_tool_arguments(raw_args)
      if tc.respond_to?(:id)
        { id: tc.id, name: tc.name, arguments: args }
      else
        { id: tc[:id] || tc["id"], name: tc[:name] || tc["name"], arguments: args }
      end
    end

    # Coerce provider-parsed arguments to a plain Hash. Some adapters
    # (Ollama's, notably) wrap them in LLM::Object — Ruby's JSON gem does
    # not recursively call #to_json on LLM::Object values when the outer
    # container is a Hash, and instead iterates as `each_pair`, producing
    # [["names",…]] on the wire instead of {"names":…}. Coerce here so
    # everything downstream (SSE frames, request specs, client dispatch)
    # sees a real Hash.
    def coerce_tool_arguments(raw)
      return {} if raw.nil?
      return raw if raw.is_a?(Hash)
      return raw.to_h if raw.respond_to?(:to_h)
      raw
    end
  end
end
