class McpToolAdapter
  # Anthropic + OpenAI enforce ^[a-zA-Z0-9_-]{1,N}$ on function names
  # (Anthropic N=128, OpenAI N=64). MCP tools brokered by Smithery / Glama /
  # Composio are typically dot-namespaced as "<server>.<tool>", which those
  # providers reject. Sanitize the exposed name (dots → underscores, cap to
  # the strictest limit) while keeping the original for the MCP invocation
  # so tool calls still route back to the real tool.
  NAME_PATTERN = /[^a-zA-Z0-9_-]/
  MAX_NAME_LEN = 64

  class << self
    def to_llm_functions(mcp_tools)
      exposed = unique_exposed_names(mcp_tools.map { sanitize_name(it.name) })
      mcp_tools.each_with_index.map { |t, i| build_function(t, exposed[i]) }
    end

    private

    def build_function(mcp_tool, exposed_name)
      server_url    = mcp_tool.mcp_server.url
      auth_token    = mcp_tool.mcp_server.auth_token
      original_name = mcp_tool.name

      LLM::Function.new(exposed_name) do |fn|
        fn.description mcp_tool.description
        set_params(fn, mcp_tool.input_schema)
        fn.define ->(**arguments) {
          McpClient.new(server_url, auth_token: auth_token).tap(&:initialize_connection!).call_tool!(original_name, arguments)
        }
      end
    end

    def sanitize_name(name)
      name.to_s.gsub(NAME_PATTERN, "_")[0, MAX_NAME_LEN]
    end

    # First occurrence keeps its sanitized name; subsequent duplicates get
    # "_2", "_3", ... suffixed. The suffix eats into the base name to stay
    # under MAX_NAME_LEN, and we re-check against `used` to avoid cascading
    # collisions where a dedupe-generated name (`foo_2`) clashes with a
    # later tool that already sanitized to `foo_2`.
    def unique_exposed_names(names)
      used = {}
      names.map do |name|
        candidate = name
        n = 1
        while used.key?(candidate)
          n += 1
          suffix = "_#{n}"
          candidate = "#{name[0, MAX_NAME_LEN - suffix.length]}#{suffix}"
        end
        used[candidate] = true
        candidate
      end
    end

    def set_params(fn, input_schema)
      return unless input_schema.is_a?(Hash)

      schema = input_schema.deep_symbolize_keys
      fn.instance_variable_set(:@params, schema)
    end
  end
end
