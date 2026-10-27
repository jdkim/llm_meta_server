require "rails_helper"

RSpec.describe "Anonymous API admission", type: :request do
  let(:headers) { { "Content-Type" => "application/json" } }
  let(:path) { "/api/llm_api_keys/anonymous/models/qwen3-8-27b-fast/single_llm_calls" }
  let(:payload) { { messages: [ { role: "user", content: "hi" } ] } }

  before do
    AnonymousUsageState.delete_all
    allow(LlmModelMap).to receive(:fetch!).and_return("glm-4.7-flash")
    allow(LlmModelMap).to receive(:ollama_model?).and_return(true)
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

  # The gate asked ollama_model? — "where does the model run" — so gpt-oss-120b
  # on Bedrock, which needs no caller key and is what pubdictionaries.org and
  # togomcp.rdfportal.org serve anonymously, was refused with 403. No example in
  # the suite covered it: every test here stubs ollama_model? to true, and
  # free_access_model? delegates to it, so the distinction never showed.
  it "admits a free-access hosted model, which is what production serves anonymously" do
    allow(LlmModelMap).to receive(:ollama_model?).and_return(false)
    allow(LlmModelMap).to receive(:free_access_model?).and_return(true)
    expect(LlmRbFacade).to receive(:single_llm_turn!)
      .and_return(content: "ok", tool_calls: [], finish_reason: "stop")

    post path, params: payload.to_json, headers: headers

    expect(response).to have_http_status(:ok)
  end

  it "refuses a model that needs the caller's own key" do
    allow(LlmModelMap).to receive(:ollama_model?).and_return(false)
    allow(LlmModelMap).to receive(:free_access_model?).and_return(false)
    expect(LlmRbFacade).not_to receive(:single_llm_turn!)

    post path, params: payload.to_json, headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).to eq("model_not_allowed")
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
  it "ignores missing and rotating Origin headers for the same IP quota" do
    expect(LlmRbFacade).to receive(:single_llm_turn!).exactly(30).times.and_return(content: "ok", tool_calls: [], finish_reason: "stop")
    30.times do |i|
      post path, params: payload.to_json, headers: headers.merge("Origin" => "https://site-#{i}.example")
      expect(response).to have_http_status(:ok)
    end
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:too_many_requests)
  end

  it "rejects anonymous house-paid models before starting inference" do
    allow(LlmModelMap).to receive(:ollama_model?).and_return(false)
    expect(LlmRbFacade).not_to receive(:single_llm_turn!)
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  [ "Bearer", "Basic abc", "", "Bearer a b" ].each do |auth|
    it "rejects malformed authorization #{auth.inspect} without anonymous fallback" do
      expect(LlmRbFacade).not_to receive(:single_llm_turn!)
      post path, params: payload.to_json, headers: headers.merge("Authorization" => auth)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "caps large catalog defaults while rejecting explicit excessive overrides" do
    allow(LlmModelMap).to receive(:defaults_for).and_return(options: { num_ctx: 262144, num_predict: 32768 })
    expect(LlmRbFacade).to receive(:single_llm_turn!) do |**args|
      expect(args[:generation_params][:options]).to include(num_ctx: 65536, num_predict: 4096)
      { content: "ok", tool_calls: [], finish_reason: "stop" }
    end
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    post path, params: payload.merge(generation_settings: { options: { num_predict: 32768 } }).to_json, headers: headers
    expect(response).to have_http_status(:bad_request)
  end

  it "authenticates a supplied invalid bearer instead of falling back to anonymous" do
    allow(GoogleIdTokenVerifier).to receive(:verify_all).with("invalid").and_raise(JWT::DecodeError, "bad token")
    expect(LlmRbFacade).not_to receive(:single_llm_turn!)
    post path, params: payload.to_json, headers: headers.merge("Authorization" => "Bearer invalid")
    expect(response).to have_http_status(:unauthorized)
  end
end
