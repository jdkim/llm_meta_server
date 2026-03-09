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
      allow(McpClient).to receive(:new).with("https://example.com/mcp").and_return(mock_client)
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
  end
end
