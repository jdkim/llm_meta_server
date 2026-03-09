module LLM
  class Session
    def extract_tool_calls
      messages
        .select { it.respond_to?(:assistant?) && it.assistant? }
        .select { it.respond_to?(:tool_call?) && it.tool_call? }
        .flat_map { it.to_h[:tools] || [] }
        .map { normalize_tool_call(it) }
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
