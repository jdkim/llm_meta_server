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

RSpec.describe McpClient, "transport failure classification" do
  let(:client) { described_class.new("https://tool.example/mcp") }

  it "reports a read timeout as upstream-uncertain, because the tool may still be running" do
    allow(HTTParty).to receive(:post).and_raise(Net::ReadTimeout)

    expect { client.send(:send_request, "tools/call", {}) }
      .to raise_error(described_class::McpUpstreamTimeoutError, /may still be running/)
  end

  it "reports a refused connection as an ordinary failure, because nothing was sent" do
    allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED)

    expect { client.send(:send_request, "tools/call", {}) }
      .to raise_error(described_class::McpConnectionError) { |e|
        expect(e).not_to be_a(described_class::McpUpstreamTimeoutError)
      }
  end

  it "reports a connect timeout as an ordinary failure, although it is a Timeout::Error" do
    allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout)

    expect { client.send(:send_request, "tools/call", {}) }
      .to raise_error(described_class::McpConnectionError) { |e|
        expect(e).not_to be_a(described_class::McpUpstreamTimeoutError)
      }
  end
end
