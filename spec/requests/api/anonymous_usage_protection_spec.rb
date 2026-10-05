require "rails_helper"

RSpec.describe "Anonymous API admission", type: :request do
  let(:headers) { { "Content-Type" => "application/json" } }
  let(:path) { "/api/llm_api_keys/anonymous/models/glm-4-7-flash/single_llm_calls" }
  let(:payload) { { messages: [ { role: "user", content: "hi" } ] } }

  before do
    AnonymousUsageState.delete_all
    allow(LlmModelMap).to receive(:fetch!).and_return("glm-4.7-flash")
    allow(LlmModelMap).to receive(:defaults_for).and_return({})
  end

  %w[chats chat_streams].each do |endpoint|
    it "blocks the anonymous legacy #{endpoint} bypass" do
      expect(LlmRbFacade).not_to receive(:call!)
      expect(LlmRbFacade).not_to receive(:stream!)
      post path.sub("single_llm_calls", endpoint), params: { prompt: "hi" }.to_json, headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "rejects unbounded generation before starting the provider or SSE" do
    expect(LlmRbFacade).not_to receive(:single_llm_turn!)
    post path, params: payload.merge(generation_settings: { options: { num_predict: -1 } }).to_json, headers: headers
    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)["error"]).to eq("invalid_input")
  end

  it "rejects a generation array as malformed input" do
    expect(LlmRbFacade).not_to receive(:single_llm_turn!)
    post path, params: payload.merge(generation_settings: []).to_json, headers: headers
    expect(response).to have_http_status(:bad_request)
  end

  it "returns Retry-After and never calls the provider when the IP slot is occupied" do
    AnonymousUsagePolicy.new.acquire!(kind: "llm", ip: "127.0.0.1")
    expect(LlmRbFacade).not_to receive(:single_llm_turn!)
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"]).to eq("5")
  end

  it "returns 503 before the provider when anonymous inference is stopped" do
    AnonymousUsagePolicy.set_enabled!("llm", false, actor: "spec", reason: "incident")
    expect(LlmRbFacade).not_to receive(:single_llm_turn!)
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:service_unavailable)
    expect(JSON.parse(response.body)["error"]).to eq("stopped")
  end

  it "admits two tool-result turns with bounded settings and releases both slots" do
    expect(LlmRbFacade).to receive(:single_llm_turn!).twice do |**args|
      expect(args[:generation_params][:options]).to include(num_ctx: 65536, num_predict: 4096)
      { content: "ok", tool_calls: [], finish_reason: "stop" }
    end
    2.times do
      post path, params: payload.to_json, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("event: done")
      expect(AnonymousUsageState.first.state["leases"]).to be_empty
    end
  end
end
