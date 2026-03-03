require 'rails_helper'

RSpec.describe McpClient do
  let(:url) { "https://example.com/mcp" }
  let(:client) { described_class.new(url) }

  describe '#initialize_connection!' do
    context 'when server responds with JSON' do
      let(:init_response) do
        instance_double(
          HTTParty::Response,
          success?: true,
          code: 200,
          headers: { "content-type" => "application/json", "mcp-session-id" => "session-123" },
          body: {
            jsonrpc: "2.0",
            id: 1,
            result: {
              protocolVersion: "2025-03-26",
              serverInfo: { name: "test-server", version: "1.0.0" },
              capabilities: {}
            }
          }.to_json
        )
      end

      let(:notification_response) do
        instance_double(
          HTTParty::Response,
          success?: true,
          code: 200,
          headers: {},
          body: ""
        )
      end

      before do
        allow(HTTParty).to receive(:post).and_return(init_response, notification_response)
      end

      it 'initializes connection and stores server info' do
        result = client.initialize_connection!

        expect(result["serverInfo"]["name"]).to eq("test-server")
        expect(result["serverInfo"]["version"]).to eq("1.0.0")
        expect(result["protocolVersion"]).to eq("2025-03-26")
        expect(client.session_id).to eq("session-123")
        expect(client.server_info).to eq({ "name" => "test-server", "version" => "1.0.0" })
        expect(client.protocol_version).to eq("2025-03-26")
      end
    end

    context 'when server responds with SSE' do
      let(:sse_body) do
        "data: #{{ jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-03-26', serverInfo: { name: 'sse-server', version: '2.0.0' }, capabilities: {} } }.to_json}\n\n"
      end

      let(:init_response) do
        instance_double(
          HTTParty::Response,
          success?: true,
          code: 200,
          headers: { "content-type" => "text/event-stream", "mcp-session-id" => "sse-session" },
          body: sse_body
        )
      end

      let(:notification_response) do
        instance_double(
          HTTParty::Response,
          success?: true,
          code: 200,
          headers: {},
          body: ""
        )
      end

      before do
        allow(HTTParty).to receive(:post).and_return(init_response, notification_response)
      end

      it 'parses SSE response correctly' do
        result = client.initialize_connection!

        expect(result["serverInfo"]["name"]).to eq("sse-server")
        expect(client.session_id).to eq("sse-session")
      end
    end

    context 'when connection fails' do
      before do
        allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED, "Connection refused")
      end

      it 'raises McpConnectionError' do
        expect { client.initialize_connection! }.to raise_error(
          McpClient::McpConnectionError, /Failed to connect to MCP server/
        )
      end
    end

    context 'when server returns HTTP error' do
      let(:error_response) do
        instance_double(
          HTTParty::Response,
          success?: false,
          code: 500,
          headers: {}
        )
      end

      before do
        allow(HTTParty).to receive(:post).and_return(error_response)
      end

      it 'raises McpConnectionError' do
        expect { client.initialize_connection! }.to raise_error(
          McpClient::McpConnectionError, /HTTP 500/
        )
      end
    end

    context 'when server returns JSON-RPC error' do
      let(:error_response) do
        instance_double(
          HTTParty::Response,
          success?: true,
          code: 200,
          headers: { "content-type" => "application/json" },
          body: {
            jsonrpc: "2.0",
            id: 1,
            error: { code: -32600, message: "Invalid Request" }
          }.to_json
        )
      end

      before do
        allow(HTTParty).to receive(:post).and_return(error_response)
      end

      it 'raises McpProtocolError' do
        expect { client.initialize_connection! }.to raise_error(
          McpClient::McpProtocolError, /JSON-RPC error -32600: Invalid Request/
        )
      end
    end
  end

  describe '#list_tools!' do
    let(:init_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        code: 200,
        headers: { "content-type" => "application/json", "mcp-session-id" => "session-123" },
        body: {
          jsonrpc: "2.0",
          id: 1,
          result: {
            protocolVersion: "2025-03-26",
            serverInfo: { name: "test-server", version: "1.0.0" },
            capabilities: {}
          }
        }.to_json
      )
    end

    let(:notification_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        code: 200,
        headers: {},
        body: ""
      )
    end

    let(:tools_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        code: 200,
        headers: { "content-type" => "application/json", "mcp-session-id" => "session-123" },
        body: {
          jsonrpc: "2.0",
          id: 2,
          result: {
            tools: [
              {
                name: "read_file",
                description: "Read a file from disk",
                inputSchema: { type: "object", properties: { path: { type: "string" } } }
              },
              {
                name: "write_file",
                description: "Write a file to disk",
                inputSchema: { type: "object", properties: { path: { type: "string" }, content: { type: "string" } } }
              }
            ]
          }
        }.to_json
      )
    end

    before do
      allow(HTTParty).to receive(:post).and_return(init_response, notification_response, tools_response)
      client.initialize_connection!
    end

    it 'returns list of tools' do
      tools = client.list_tools!

      expect(tools.length).to eq(2)
      expect(tools[0]["name"]).to eq("read_file")
      expect(tools[1]["name"]).to eq("write_file")
    end
  end
end
