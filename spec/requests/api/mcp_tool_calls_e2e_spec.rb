require "rails_helper"

# E2E for the MCP-tool-call proxy endpoint used by the client-orchestrated
# JS loop. Stubs the MCP server's JSON-RPC responses; ApiController auth,
# McpTool.lookup visibility, and McpClient all run for real.
RSpec.describe "POST /api/mcp_tools/:tool_id/call (E2E)", type: :request do
  let(:user)        { User.create!(email: "u@example.com", google_id: "g-mtc") }
  let(:good_token)  { "tok" }
  let(:auth_headers) do
    { "Authorization" => "Bearer #{good_token}", "Content-Type" => "application/json" }
  end
  let(:mcp_url)     { "http://mcp.test/rpc" }

  before do
    allow(GoogleIdTokenVerifier).to receive(:verify_all)
      .with(good_token).and_return("sub" => user.google_id)
  end

  # JSON-RPC MCP stub — dispatches on `method` in the request body.
  def stub_mcp(tool_result_text: "ok", tool_is_error: false)
    stub_request(:post, mcp_url).to_return do |req|
      body = JSON.parse(req.body)
      case body["method"]
      when "initialize"
        { status: 200, headers: { "Content-Type" => "application/json" },
          body: { jsonrpc: "2.0", id: body["id"],
                  result: { protocolVersion: "2025-03-26",
                            serverInfo: { name: "test-mcp", version: "1.0.0" } } }.to_json }
      when "notifications/initialized"
        { status: 200, body: "", headers: {} }
      when "tools/call"
        { status: 200, headers: { "Content-Type" => "application/json" },
          body: { jsonrpc: "2.0", id: body["id"],
                  result: { content: [ { type: "text", text: tool_result_text } ],
                            isError: tool_is_error } }.to_json }
      else
        { status: 500, body: "Unknown method: #{body['method']}" }
      end
    end
  end

  def create_tool!(owner: user, active: true, server_active: true, public: false, name: "search")
    server = owner.mcp_servers.create!(name: "s", url: mcp_url, active: server_active, public: public)
    server.mcp_tools.create!(name: name, description: "d",
                             input_schema: { "type" => "object", "properties" => {} },
                             active: active)
  end

  it "invokes the MCP tool with the given arguments and returns { result: … }" do
    tool = create_tool!
    stub_mcp(tool_result_text: "found 3 dictionaries")

    post "/api/mcp_tools/#{tool.id}/call",
         params: { arguments: { q: "anatomy" } }.to_json,
         headers: auth_headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body).to have_key("result")
    expect(body["result"]).to include(
      "content" => [ { "type" => "text", "text" => "found 3 dictionaries" } ],
      "isError" => false
    )

    # tools/call reached the MCP server with the tool's original name + args.
    expect(WebMock).to have_requested(:post, mcp_url).with { |req|
      b = JSON.parse(req.body)
      b["method"] == "tools/call" && b["params"] == { "name" => "search", "arguments" => { "q" => "anatomy" } }
    }
  end

  it "defaults arguments to {} when omitted" do
    tool = create_tool!
    stub_mcp

    post "/api/mcp_tools/#{tool.id}/call", params: "{}", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(WebMock).to have_requested(:post, mcp_url).with { |req|
      b = JSON.parse(req.body)
      b["method"] == "tools/call" && b["params"]["arguments"] == {}
    }
  end

  it "returns 404 when the tool_id doesn't exist" do
    stub_mcp
    post "/api/mcp_tools/999999/call", params: "{}", headers: auth_headers
    expect(response).to have_http_status(:unauthorized) # ApiController rescues RecordNotFound → :unauthorized
    expect(WebMock).not_to have_requested(:post, mcp_url)
  end

  it "returns 401 for another user's private (non-public) tool" do
    other = User.create!(email: "other@example.com", google_id: "g-other")
    tool  = create_tool!(owner: other, public: false)
    stub_mcp

    post "/api/mcp_tools/#{tool.id}/call", params: "{}", headers: auth_headers
    expect(response).to have_http_status(:unauthorized)
    expect(WebMock).not_to have_requested(:post, mcp_url)
  end

  it "allows another user's PUBLIC + active tool (visibility rule mirrors chat flow)" do
    other = User.create!(email: "public@example.com", google_id: "g-public")
    tool  = create_tool!(owner: other, public: true)
    stub_mcp(tool_result_text: "public tool result")

    post "/api/mcp_tools/#{tool.id}/call",
         params: { arguments: {} }.to_json, headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("result", "content", 0, "text")).to eq("public tool result")
  end

  it "returns 502 when the MCP server is unreachable" do
    tool = create_tool!
    stub_request(:post, mcp_url).to_raise(Errno::ECONNREFUSED)

    post "/api/mcp_tools/#{tool.id}/call", params: "{}", headers: auth_headers

    expect(response).to have_http_status(:bad_gateway)
    body = JSON.parse(response.body)
    expect(body["error"]).to eq("MCP server connection failed")
  end

  it "returns 401 without a bearer token" do
    tool = create_tool!
    post "/api/mcp_tools/#{tool.id}/call", params: "{}",
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:bad_request).or have_http_status(:unauthorized)
  end
end
