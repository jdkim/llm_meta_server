require 'rails_helper'

RSpec.describe McpToolAdapter do
  let(:user) { User.create!(email: "test@example.com", google_id: "google-123") }
  let(:mcp_server) do
    McpServer.create!(
      user: user,
      name: "Test Server",
      url: "https://example.com/mcp",
      active: true,
      server_name: "test-server",
      server_version: "1.0.0",
      protocol_version: "2025-03-26"
    )
  end

  let(:mcp_tool) do
    McpTool.create!(
      mcp_server: mcp_server,
      name: "read_file",
      description: "Read a file from disk",
      input_schema: {
        "type" => "object",
        "properties" => {
          "path" => { "type" => "string", "description" => "File path to read" }
        },
        "required" => [ "path" ]
      },
      active: true
    )
  end

  describe '.to_llm_functions' do
    it 'converts MCP tools to LLM::Function objects' do
      functions = described_class.to_llm_functions([ mcp_tool ])

      expect(functions.length).to eq(1)
      expect(functions[0]).to be_a(LLM::Function)
      expect(functions[0].name).to eq("read_file")
      expect(functions[0].description).to eq("Read a file from disk")
    end

    it 'sets input schema as function params' do
      functions = described_class.to_llm_functions([ mcp_tool ])
      fn = functions[0]

      params = fn.params
      expect(params[:type]).to eq("object")
      expect(params[:properties][:path][:type]).to eq("string")
      expect(params[:required]).to eq([ "path" ])
    end

    it 'creates a callable runner that invokes MCP server' do
      functions = described_class.to_llm_functions([ mcp_tool ])
      fn = functions[0]

      mock_client = instance_double(McpClient)
      allow(McpClient).to receive(:new).with("https://example.com/mcp", auth_token: nil).and_return(mock_client)
      allow(mock_client).to receive(:initialize_connection!)
      allow(mock_client).to receive(:call_tool!).with("read_file", { path: "/tmp/test.txt" }).and_return(
        { "content" => [ { "type" => "text", "text" => "file content" } ] }
      )

      fn.id = "call-123"
      fn.arguments = { path: "/tmp/test.txt" }
      result = fn.call

      expect(result).to be_a(LLM::Function::Return)
      expect(result.id).to eq("call-123")
      expect(result.name).to eq("read_file")
      expect(result.value["content"][0]["text"]).to eq("file content")
    end

    it "threads the server's auth_token into McpClient.new when the server has one" do
      mcp_server.auth_token = "mcp_secret_token"
      mcp_server.save!
      mcp_tool.reload

      functions = described_class.to_llm_functions([ mcp_tool ])
      fn = functions[0]

      mock_client = instance_double(McpClient)
      # This is the crux — the auth_token from the server must reach the client
      # constructor, otherwise every call to an authenticated server would fail.
      expect(McpClient).to receive(:new).with("https://example.com/mcp", auth_token: "mcp_secret_token").and_return(mock_client)
      allow(mock_client).to receive(:initialize_connection!)
      allow(mock_client).to receive(:call_tool!).with("read_file", { path: "/tmp/x" }).and_return({ "content" => [] })

      fn.id = "call-authed"
      fn.arguments = { path: "/tmp/x" }
      fn.call
    end

    it 'handles multiple tools' do
      tool2 = McpTool.create!(
        mcp_server: mcp_server,
        name: "write_file",
        description: "Write a file to disk",
        input_schema: {
          "type" => "object",
          "properties" => {
            "path" => { "type" => "string" },
            "content" => { "type" => "string" }
          },
          "required" => [ "path", "content" ]
        },
        active: true
      )

      functions = described_class.to_llm_functions([ mcp_tool, tool2 ])

      expect(functions.length).to eq(2)
      expect(functions.map(&:name)).to eq([ "read_file", "write_file" ])
    end

    it 'handles tool with nil input_schema gracefully' do
      tool_no_schema = McpTool.new(
        mcp_server: mcp_server,
        name: "ping",
        description: "Ping the server",
        input_schema: { "type" => "object" },
        active: true
      )
      tool_no_schema.save!

      functions = described_class.to_llm_functions([ tool_no_schema ])
      expect(functions[0].name).to eq("ping")
    end

    describe "tool name sanitization" do
      # Anthropic + OpenAI reject function names outside ^[a-zA-Z0-9_-]{1,N}$.
      # MCP tools from Smithery/Glama/Composio are commonly dot-namespaced
      # ("<server>.<tool>") — every such tool would 400 without sanitization.

      def build_tool(name)
        McpTool.create!(
          mcp_server: mcp_server,
          name: name,
          description: "t",
          input_schema: { "type" => "object" },
          active: true
        )
      end

      it "replaces dots (and other disallowed chars) in the exposed function name" do
        fn = described_class.to_llm_functions([ build_tool("tubealfred-youtube.youtube_video_get") ]).first
        expect(fn.name).to eq("tubealfred-youtube_youtube_video_get")
        expect(fn.name).to match(/\A[a-zA-Z0-9_-]{1,64}\z/)
      end

      it "leaves already-valid names unchanged" do
        fn = described_class.to_llm_functions([ build_tool("read_file") ]).first
        expect(fn.name).to eq("read_file")
      end

      it "truncates names longer than the strictest provider limit (64)" do
        long = "a" * 100
        fn = described_class.to_llm_functions([ build_tool(long) ]).first
        expect(fn.name.length).to eq(64)
      end

      it "invokes the MCP with the ORIGINAL (unsanitized) name, so tool calls still route" do
        tool = build_tool("googledrive.find_file")
        fn = described_class.to_llm_functions([ tool ]).first

        mock_client = instance_double(McpClient)
        allow(McpClient).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:initialize_connection!)
        # The sanitized name goes to the LLM, but the MCP call must use the
        # original dot-namespaced name — otherwise the MCP server rejects it.
        expect(mock_client).to receive(:call_tool!).with("googledrive.find_file", { q: "presentations" }).and_return({ "content" => [] })

        fn.id = "call-1"
        fn.arguments = { q: "presentations" }
        fn.call

        expect(fn.name).to eq("googledrive_find_file")
      end

      it "replaces any mix of disallowed characters uniformly" do
        # Proves the property "anything outside [a-zA-Z0-9_-] becomes _"
        # without needing one test per character class.
        fn = described_class.to_llm_functions([ build_tool("weird tool/name:v1.beta") ]).first
        expect(fn.name).to eq("weird_tool_name_v1_beta")
      end

      it "assigns distinct exposed names when originals collide after sanitization" do
        # `foo.bar` and `foo/bar` both sanitize to `foo_bar` — without a
        # collision guard the LLM would see two functions with the same name.
        tool_a = build_tool("foo.bar")
        tool_b = build_tool("foo/bar")
        fns = described_class.to_llm_functions([ tool_a, tool_b ])

        expect(fns.map(&:name)).to eq([ "foo_bar", "foo_bar_2" ])
      end

      it "routes each collided tool to its own original name on invocation" do
        # Guarantees the dedupe suffix doesn't scramble which MCP call fires.
        tool_a = build_tool("search.query")
        tool_b = build_tool("search/query")
        fn_a, fn_b = described_class.to_llm_functions([ tool_a, tool_b ])

        mock_client = instance_double(McpClient)
        allow(McpClient).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:initialize_connection!)

        expect(mock_client).to receive(:call_tool!).with("search.query", { q: "a" }).and_return({ "content" => [] })
        fn_a.id = "call-a"
        fn_a.arguments = { q: "a" }
        fn_a.call

        expect(mock_client).to receive(:call_tool!).with("search/query", { q: "b" }).and_return({ "content" => [] })
        fn_b.id = "call-b"
        fn_b.arguments = { q: "b" }
        fn_b.call
      end

      it "handles cascading collisions (a dedupe-generated name collides with a later original)" do
        # foo.bar → foo_bar. foo/bar → foo_bar (collision) → foo_bar_2.
        # foo_bar_2 is already the sanitized name of the third tool → must
        # bump to foo_bar_2_2.
        tools = [ build_tool("foo.bar"), build_tool("foo/bar"), build_tool("foo_bar_2") ]
        fns = described_class.to_llm_functions(tools)

        expect(fns.map(&:name)).to eq([ "foo_bar", "foo_bar_2", "foo_bar_2_2" ])
      end
    end
  end
end
