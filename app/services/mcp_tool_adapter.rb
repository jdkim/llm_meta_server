class McpToolAdapter
  class << self
    def to_llm_functions(mcp_tools)
      mcp_tools.map { build_function(it) }
    end

    private

    def build_function(mcp_tool)
      server_url = mcp_tool.mcp_server.url
      tool_name = mcp_tool.name

      LLM::Function.new(tool_name) do |fn|
        fn.description mcp_tool.description
        set_params(fn, mcp_tool.input_schema)
        fn.define ->(**arguments) {
          McpClient.new(server_url).tap(&:initialize_connection!).call_tool!(tool_name, arguments)
        }
      end
    end

    def set_params(fn, input_schema)
      return unless input_schema.is_a?(Hash)

      schema = input_schema.deep_symbolize_keys
      fn.instance_variable_set(:@params, schema)
    end
  end
end
