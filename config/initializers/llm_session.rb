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
      if tc.respond_to?(:id)
        { id: tc.id, name: tc.name, arguments: tc.arguments }
      else
        { id: tc[:id] || tc["id"], name: tc[:name] || tc["name"], arguments: tc[:arguments] || tc["arguments"] }
      end
    end
  end
end
