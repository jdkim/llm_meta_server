require "rails_helper"
require Rails.root.join("lib/anonymous_request_body_limit")

RSpec.describe AnonymousRequestBodyLimit do
  let(:app) { ->(env) { [ 200, {}, [ env["rack.input"].read ] ] } }
  let(:middleware) { described_class.new(app) }
  let(:env) { { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/api/mcp_tools/1/call", "rack.input" => StringIO.new("{}") } }

  it "preserves accepted bodies for the JSON parser" do
    expect(middleware.call(env)).to eq([ 200, {}, [ "{}" ] ])
  end

  it "rejects Content-Length and chunked/undeclared bodies before the app" do
    expect(app).not_to receive(:call)
    expect(middleware.call(env.merge("CONTENT_LENGTH" => "262145"))[0]).to eq(413)
    expect(middleware.call(env.merge("rack.input" => StringIO.new("x" * 262145)))[0]).to eq(413)
  end

  it "leaves discovery and unrelated routes unchanged" do
    expect(middleware.call(env.merge("PATH_INFO" => "/api/mcp_servers"))[0]).to eq(200)
  end
  it "also covers Rails format suffixes and the legacy inference endpoints" do
    %w[/api/llm_api_keys/a/models/b/single_llm_calls.json /api/mcp_tools/1/call.json /api/llm_api_keys/a/models/b/chats /api/llm_api_keys/a/models/b/chat_streams].each do |path|
      expect(described_class::PATH.match?(path)).to be true
    end
  end
end
