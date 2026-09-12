require "rails_helper"

# E2E for function tools on the Responses endpoint over the NON-streaming JSON
# API (`POST /api/.../chats`).
#
# This path was left unfixed when the SSE endpoint gained Responses tool
# support: Api::ChatsController never told the facade which endpoint the model
# wanted, so `call!` always used chat completions and a reasoning model with
# tools still hit OpenAI's refusal. These specs pin both the routing and the
# JSON envelope the client gets back.
#
# Only the two upstream hops are stubbed — OpenAI's Responses SSE and the MCP
# server's JSON-RPC. Everything between runs for real.
RSpec.describe "POST /api/.../chats with tools on the Responses API (E2E)", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-nrtool") }
  let(:good_token) { "tok" }
  let(:auth_headers) { { "Authorization" => "Bearer #{good_token}" } }

  let!(:openai_key) do
    user.llm_api_keys.create!(llm_type: "openai", description: "p",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-test"))
  end

  let(:mcp_url) { "https://mcp.example.com/jsonrpc" }
  let!(:mcp_server) { user.mcp_servers.create!(name: "test-mcp", url: mcp_url, active: true) }
  let!(:lookup_tool) do
    mcp_server.mcp_tools.create!(
      name: "find_ids",
      description: "Look up ids for terms",
      input_schema: {
        type: "object",
        properties: { labels: { type: "string" }, dictionary: { type: "string" } },
        required: [ "labels" ]
      },
      active: true
    )
  end

  before do
    allow(GoogleIdTokenVerifier).to receive(:verify_all)
      .with(good_token).and_return("sub" => user.google_id)
  end

  def sse(events)
    events.map { |e| "event: #{e[:type]}\ndata: #{e.to_json}\n\n" }.join
  end

  def tool_call_round(response_id:, call_id:, name:, arguments:)
    sse([
      { type: "response.created", response: { id: response_id, status: "in_progress" } },
      { type: "response.output_item.added", output_index: 0,
        item: { type: "function_call", id: "fc_1", call_id: call_id, name: name, arguments: "" } },
      { type: "response.output_item.done", output_index: 0,
        item: { type: "function_call", id: "fc_1", call_id: call_id, name: name, arguments: arguments } },
      { type: "response.completed", response: { id: response_id, status: "completed" } }
    ])
  end

  def answer_round(response_id:, text:)
    sse([
      { type: "response.created", response: { id: response_id, status: "in_progress" } },
      { type: "response.output_item.added", output_index: 0,
        item: { type: "message", role: "assistant", content: [] } },
      { type: "response.content_part.added", output_index: 0, content_index: 0,
        part: { type: "output_text", text: "" } },
      { type: "response.output_text.delta", output_index: 0, content_index: 0, delta: text },
      { type: "response.completed", response: { id: response_id, status: "completed" } }
    ])
  end

  def stub_openai_rounds(*bodies)
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(
      *bodies.map { |b| { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: b } }
    )
  end

  def stub_mcp_server(text: "HP:0001250")
    stub_request(:post, mcp_url).to_return do |req|
      body = JSON.parse(req.body)
      case body["method"]
      when "initialize"
        { status: 200,
          headers: { "Content-Type" => "application/json", "mcp-session-id" => "s" },
          body: { jsonrpc: "2.0", id: body["id"],
                  result: { protocolVersion: "2025-03-26",
                            serverInfo: { name: "m", version: "1" } } }.to_json }
      when "notifications/initialized"
        { status: 200, body: "", headers: {} }
      else
        { status: 200, headers: { "Content-Type" => "application/json" },
          body: { jsonrpc: "2.0", id: body["id"],
                  result: { content: [ { type: "text", text: text } ] } }.to_json }
      end
    end
  end

  def post_chat!(tool_ids: [ lookup_tool.id ])
    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chats",
         params: { prompt: "ids for seizure?", tool_ids: tool_ids },
         headers: auth_headers
  end

  it "routes a reasoning model with tools to Responses, not chat completions" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "find_ids", arguments: %({"labels":"seizure"})),
      answer_round(response_id: "resp_2", text: "Found one id.")
    )
    stub_mcp_server

    post_chat!

    expect(response).to have_http_status(:ok)
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/responses").twice
    expect(WebMock).not_to have_requested(:post, "https://api.openai.com/v1/chat/completions")
  end

  it "returns the assistant message and the executed tool calls" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "find_ids", arguments: %({"labels":"seizure"})),
      answer_round(response_id: "resp_2", text: "Found one id.")
    )
    stub_mcp_server(text: "HP:0001250")

    post_chat!

    body = JSON.parse(response.body)
    expect(body["response"]["message"]).to include("Found one id.")
    expect(body["response"]["tool_calls"].length).to eq(1)
    expect(body["response"]["tool_calls"].first).to include(
      "id" => "call_1", "name" => "find_ids"
    )
    expect(body["response"]["tool_calls"].first["result"]).to include("HP:0001250")
  end

  # The non-streaming chat-completions path runs exactly one tool round. This
  # one shares the streaming loop, so it keeps going until the model stops
  # asking — worth pinning, because it is a real behavioural difference.
  it "runs more than one tool round when the model keeps asking" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "c1",
                      name: "find_ids", arguments: %({"labels":"seizure"})),
      tool_call_round(response_id: "resp_2", call_id: "c2",
                      name: "find_ids", arguments: %({"labels":"ataxia"})),
      answer_round(response_id: "resp_3", text: "Found both.")
    )
    stub_mcp_server

    post_chat!

    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/responses").times(3)
    body = JSON.parse(response.body)
    expect(body["response"]["message"]).to include("Found both.")
    expect(body["response"]["tool_calls"].map { |c| c["id"] }).to eq(%w[c1 c2])
  end

  # With no tools the envelope must stay a bare message, exactly as the
  # chat-completions path returns it.
  it "returns a plain message when no tools were requested" do
    stub_openai_rounds(answer_round(response_id: "resp_1", text: "No tools needed."))

    post_chat!(tool_ids: [])

    body = JSON.parse(response.body)
    expect(body["response"]["message"]).to eq("No tools needed.")
    expect(body["response"]).not_to have_key("tool_calls")
  end

  # Text the model writes before calling a tool is part of the answer; the
  # streaming path stopped discarding it in #188 and this path inherits that.
  it "keeps text written before the tool call" do
    preamble = sse([
      { type: "response.created", response: { id: "resp_1", status: "in_progress" } },
      { type: "response.output_item.added", output_index: 0,
        item: { type: "message", role: "assistant", content: [] } },
      { type: "response.content_part.added", output_index: 0, content_index: 0,
        part: { type: "output_text", text: "" } },
      { type: "response.output_text.delta", output_index: 0, content_index: 0,
        delta: "Let me look that up. " },
      { type: "response.output_item.added", output_index: 1,
        item: { type: "function_call", id: "fc_1", call_id: "c1",
                name: "find_ids", arguments: "" } },
      { type: "response.output_item.done", output_index: 1,
        item: { type: "function_call", id: "fc_1", call_id: "c1",
                name: "find_ids", arguments: %({"labels":"seizure"}) } },
      { type: "response.completed", response: { id: "resp_1", status: "completed" } }
    ])
    stub_openai_rounds(preamble, answer_round(response_id: "resp_2", text: "Found it."))
    stub_mcp_server

    post_chat!

    message = JSON.parse(response.body).dig("response", "message")
    expect(message).to include("Let me look that up.")
    expect(message).to include("Found it.")
  end
end
