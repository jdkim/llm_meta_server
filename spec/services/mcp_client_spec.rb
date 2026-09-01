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

      it 'raises McpConnectionError with the method name for grep-friendly logs' do
        expect { client.initialize_connection! }.to raise_error(
          McpClient::McpConnectionError, /Failed to send request 'initialize'/
        )
      end
    end

    context "when the server closes the connection immediately after receiving notifications/initialized" do
      # Regression guard for the "silent stop after initialize" bug: MCP
      # notifications are fire-and-forget per JSON-RPC 2.0, so a spec-
      # compliant server that closes the TCP connection right after
      # receiving `notifications/initialized` (nothing to say back) used
      # to crash initialize_connection! with Net::ReadTimeout, leaving
      # the MCP server seeing `initialize` and then radio silence. We
      # now swallow the post-write timeout on notifications specifically.
      let(:init_response) do
        instance_double(
          HTTParty::Response,
          success?: true,
          code: 200,
          headers: { "content-type" => "application/json", "mcp-session-id" => "s-1" },
          body: {
            jsonrpc: "2.0", id: 1,
            result: { protocolVersion: "2025-03-26",
                      serverInfo: { name: "srv", version: "1.0.0" }, capabilities: {} }
          }.to_json
        )
      end

      before do
        # First HTTParty.post (initialize) succeeds; second one (notifications/initialized)
        # raises Net::ReadTimeout — the write reached the server, and the
        # server closed without a response.
        call = 0
        allow(HTTParty).to receive(:post) do |*_args|
          call += 1
          call == 1 ? init_response : raise(Net::ReadTimeout.new("Net::ReadTimeout with #<TCPSocket:(closed)>"))
        end
      end

      it "completes initialize_connection! successfully (notification is fire-and-forget)" do
        expect { client.initialize_connection! }.not_to raise_error
        expect(client.server_info).to eq({ "name" => "srv", "version" => "1.0.0" })
      end
    end

    context "when the server negotiates a different protocol version" do
      # Server offers a newer version than we requested. Per spec this is
      # allowed; we accept it but log a warning so version-drift issues
      # are diagnosable when tools start behaving oddly.
      let(:init_response) do
        instance_double(
          HTTParty::Response,
          success?: true, code: 200,
          headers: { "content-type" => "application/json" },
          body: {
            jsonrpc: "2.0", id: 1,
            result: { protocolVersion: "2025-06-18",
                      serverInfo: { name: "srv", version: "1.0.0" }, capabilities: {} }
          }.to_json
        )
      end
      let(:notification_response) do
        instance_double(HTTParty::Response, success?: true, code: 200, headers: {}, body: "")
      end

      before do
        allow(HTTParty).to receive(:post).and_return(init_response, notification_response)
      end

      it "accepts the server's version and logs a warning naming both" do
        expect(Rails.logger).to receive(:warn).with(/requested 2025-03-26, server offered 2025-06-18/)
        client.initialize_connection!
        expect(client.protocol_version).to eq("2025-06-18")
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

  describe '#call_tool!' do
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

    let(:call_tool_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        code: 200,
        headers: { "content-type" => "application/json", "mcp-session-id" => "session-123" },
        body: {
          jsonrpc: "2.0",
          id: 2,
          result: {
            content: [
              { type: "text", text: "Hello, World!" }
            ]
          }
        }.to_json
      )
    end

    before do
      allow(HTTParty).to receive(:post).and_return(init_response, notification_response, call_tool_response)
      client.initialize_connection!
    end

    it 'calls a tool and returns the result' do
      result = client.call_tool!("greet", { name: "World" })

      expect(result["content"][0]["type"]).to eq("text")
      expect(result["content"][0]["text"]).to eq("Hello, World!")
    end

    context 'when tool call fails with JSON-RPC error' do
      let(:error_response) do
        instance_double(
          HTTParty::Response,
          success?: true,
          code: 200,
          headers: { "content-type" => "application/json" },
          body: {
            jsonrpc: "2.0",
            id: 3,
            error: { code: -32602, message: "Invalid params" }
          }.to_json
        )
      end

      before do
        allow(HTTParty).to receive(:post).and_return(init_response, notification_response, error_response)
        client.initialize_connection!
      end

      it 'raises McpProtocolError' do
        expect { client.call_tool!("bad_tool", {}) }.to raise_error(
          McpClient::McpProtocolError, /Invalid params/
        )
      end
    end
  end

  describe 'auth_token: header injection' do
    let(:init_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        code: 200,
        headers: { "content-type" => "application/json", "mcp-session-id" => "session-auth" },
        body: {
          jsonrpc: "2.0",
          id: 1,
          result: {
            protocolVersion: "2025-03-26",
            serverInfo: { name: "authed-server", version: "1.0.0" },
            capabilities: {}
          }
        }.to_json
      )
    end

    let(:notification_response) do
      instance_double(HTTParty::Response, success?: true, code: 200, headers: {}, body: "")
    end

    it "sends Authorization: Bearer <token> when auth_token: is given" do
      authed = described_class.new(url, auth_token: "mcp_deadbeef")
      captured = []
      allow(HTTParty).to receive(:post) do |_url, opts|
        captured << opts[:headers]
        init_response
      end.and_return(init_response, notification_response)

      authed.initialize_connection!

      # First call is initialize (request), second is the notifications/initialized (notification).
      # Both must carry the Authorization header.
      expect(captured).not_to be_empty
      captured.each do |h|
        expect(h["Authorization"]).to eq("Bearer mcp_deadbeef")
      end
    end

    it "omits Authorization header when auth_token: is not given" do
      unauth = described_class.new(url)
      captured = []
      allow(HTTParty).to receive(:post) do |_url, opts|
        captured << opts[:headers]
        init_response
      end.and_return(init_response, notification_response)

      unauth.initialize_connection!

      expect(captured).not_to be_empty
      captured.each { |h| expect(h).not_to have_key("Authorization") }
    end

    it "omits Authorization header when auth_token: is nil or blank string" do
      [ nil, "" ].each do |empty|
        client = described_class.new(url, auth_token: empty)
        captured = nil
        allow(HTTParty).to receive(:post) do |_url, opts|
          captured = opts[:headers]
          init_response
        end.and_return(init_response, notification_response)

        client.initialize_connection!
        expect(captured).not_to have_key("Authorization"), "expected no Authorization header for auth_token=#{empty.inspect}"
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
