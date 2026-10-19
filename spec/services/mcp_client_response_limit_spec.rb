require "rails_helper"

RSpec.describe "MCP response budget" do
  it "aborts an oversized upstream response before JSON parsing" do
    stub_request(:post, "http://mcp.test/rpc").to_return(
      body: { jsonrpc: "2.0", id: 1, result: { content: [ { type: "text", text: "x" * 1000 } ] } }.to_json,
      headers: { "Content-Type" => "application/json" })
    client = McpClient.new("http://mcp.test/rpc", max_response_bytes: 128)
    expect { client.call_tool!("guide") }.to raise_error(McpClient::McpProtocolError, /exceeds 128/)
  end
end
