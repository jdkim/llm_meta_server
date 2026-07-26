module LLM
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
