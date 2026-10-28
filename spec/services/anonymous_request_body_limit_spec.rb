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
    expect(middleware.call(env.merge("CONTENT_LENGTH" => "1048577"))[0]).to eq(413)
    expect(middleware.call(env.merge("rack.input" => StringIO.new("x" * 1048577)))[0]).to eq(413)
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

RSpec.describe AnonymousRequestBodyLimit, "authenticated callers" do
  let(:app) { ->(_env) { [ 200, {}, [ "ok" ] ] } }
  let(:path) { "/api/llm_api_keys/abc/models/gpt-5/single_llm_calls" }

  def post_body(bytes, headers = {})
    env = Rack::MockRequest.env_for(path, method: "POST", input: "x" * bytes, **headers)
    described_class.new(app).call(env)
  end

  it "holds an anonymous caller to the strict limit" do
    expect(post_body(1_048_577).first).to eq(413)
  end

  it "lets a caller spending its own key post more than the anonymous limit" do
    # Their version applied the anonymous cap to everyone, so an authenticated
    # conversation carrying an extracted document hit 413 at 1 MiB.
    expect(post_body(1_048_577, "HTTP_AUTHORIZATION" => "Bearer token").first).to eq(200)
  end

  it "still bounds an authenticated body" do
    expect(post_body(8_388_609, "HTTP_AUTHORIZATION" => "Bearer token").first).to eq(413)
  end
end
