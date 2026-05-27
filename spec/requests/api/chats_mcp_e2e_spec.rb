require "rails_helper"

# End-to-end test for the MCP tool-call execution loop. Drives:
#
#   client → ApiController → ChatsController → McpToolAdapter →
#   LlmRbFacade.execute_chat_with_tools! → llm.rb → OpenAI HTTP (turn 1) →
#   McpClient JSON-RPC HTTP (initialize + tools/call) → llm.rb → OpenAI
#   HTTP (turn 2) → controller response envelope.
#
# We stub only the upstream HTTP layers (OpenAI completions, MCP JSON-RPC).
# Everything in between — including request/response adapters, session
# bookkeeping, and our extract_tool_calls override — runs for real.
RSpec.describe "POST /api/.../chats with MCP tools", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-mcp") }
  let(:good_token) { "tok" }
  let(:auth_headers) { { "Authorization" => "Bearer #{good_token}" } }

  let!(:openai_key) do
    user.llm_api_keys.create!(llm_type: "openai", description: "personal",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-test"))
  end
  let(:mcp_url) { "https://mcp.example.com/jsonrpc" }
  let!(:mcp_server) do
    user.mcp_servers.create!(name: "test-mcp", url: mcp_url, active: true)
  end
  let!(:weather_tool) do
    mcp_server.mcp_tools.create!(
      name: "weather",
      description: "Get the current weather for a city",
      input_schema: {
        type: "object",
        properties: { city: { type: "string" } },
        required: [ "city" ]
      },
      active: true
    )
  end

  before do
    allow(GoogleIdTokenVerifier).to receive(:verify_all).with(good_token)
      .and_return("sub" => user.google_id)
  end

  # Two consecutive OpenAI responses: turn 1 emits a tool_call, turn 2
  # returns the final assistant text. WebMock returns these in order.
  def stub_openai_turns
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      {
        status: 200, headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-1", model: "gpt-5",
          choices: [ {
            index: 0, finish_reason: "tool_calls",
            message: {
              role: "assistant", content: nil,
              tool_calls: [ {
                id: "call_abc", type: "function",
                function: { name: "weather", arguments: %({"city":"Tokyo"}) }
              } ]
            }
          } ],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json
      },
      {
        status: 200, headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-2", model: "gpt-5",
          choices: [ {
            index: 0, finish_reason: "stop",
            message: { role: "assistant", content: "It's sunny in Tokyo, 22°C." }
          } ],
          usage: { prompt_tokens: 30, completion_tokens: 9, total_tokens: 39 }
        }.to_json
      }
    )
  end

  # MCP JSON-RPC server: dispatches on the `method` field in the request body
  # so we can serve initialize, notifications/initialized, and tools/call
  # from a single stub.
  def stub_mcp_server(tool_result_text: "Tokyo: sunny, 22°C", tool_is_error: false)
    stub_request(:post, mcp_url).to_return do |req|
      body = JSON.parse(req.body)
      case body["method"]
      when "initialize"
        {
          status: 200,
          headers: { "Content-Type" => "application/json", "mcp-session-id" => "sess-1" },
          body: {
            jsonrpc: "2.0", id: body["id"],
            result: {
              protocolVersion: "2025-03-26",
              serverInfo: { name: "test-mcp", version: "1.0.0" }
            }
          }.to_json
        }
      when "notifications/initialized"
        { status: 200, body: "", headers: {} }
      when "tools/call"
        {
          status: 200, headers: { "Content-Type" => "application/json" },
          body: {
            jsonrpc: "2.0", id: body["id"],
            result: {
              content: [ { type: "text", text: tool_result_text } ],
              isError: tool_is_error
            }
          }.to_json
        }
      else
        { status: 500, body: "Unknown method: #{body['method']}" }
      end
    end
  end

  it "executes the tool call against the MCP server and returns the final assistant message + tool_calls" do
    stub_openai_turns
    stub_mcp_server

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chats",
         params: { prompt: "weather in Tokyo?", tool_ids: [ weather_tool.id ] },
         headers: auth_headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body["response"]["message"]).to eq("It's sunny in Tokyo, 22°C.")
    expect(body["response"]["tool_calls"].length).to eq(1)
    expect(body["response"]["tool_calls"].first).to include(
      "name" => "weather",
      "arguments" => { "city" => "Tokyo" }
    )

    # Both OpenAI turns happened.
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").twice

    # MCP server was called for tools/call with the right argument shape.
    expect(WebMock).to have_requested(:post, mcp_url).with { |req|
      body = JSON.parse(req.body)
      next false unless body["method"] == "tools/call"
      expect(body["params"]).to eq("name" => "weather", "arguments" => { "city" => "Tokyo" })
      true
    }

    # Session ID from initialize is reused on subsequent MCP calls.
    expect(WebMock).to have_requested(:post, mcp_url)
                        .with(headers: { "Mcp-Session-Id" => "sess-1" })
                        .at_least_times(1)
  end

  it "forwards the MCP tool result back to OpenAI on turn 2" do
    stub_openai_turns
    stub_mcp_server(tool_result_text: "Tokyo: sunny, 22°C")

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chats",
         params: { prompt: "weather?", tool_ids: [ weather_tool.id ] },
         headers: auth_headers

    expect(response).to have_http_status(:ok)

    # Turn 2's request body must contain a `role: "tool"` message carrying
    # the MCP result text so the model can synthesize the final answer.
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").with { |req|
      body = JSON.parse(req.body)
      tool_msg = body["messages"].find { |m| m["role"] == "tool" }
      tool_msg.present? &&
        tool_msg["tool_call_id"] == "call_abc" &&
        tool_msg["content"].to_s.include?("Tokyo: sunny, 22°C")
    }.at_least_times(1)
  end

  it "returns 502 when the MCP server is unreachable" do
    stub_openai_turns
    stub_request(:post, mcp_url).to_return(status: 502, body: "Bad gateway",
                                            headers: { "Content-Type" => "text/plain" })

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chats",
         params: { prompt: "weather?", tool_ids: [ weather_tool.id ] },
         headers: auth_headers

    expect(response).to have_http_status(:bad_gateway)
    expect(JSON.parse(response.body)["error"]).to eq("MCP server connection failed")
  end

  it "ignores tool_ids the user doesn't own" do
    other_user = User.create!(email: "o@example.com", google_id: "g-other")
    other_server = other_user.mcp_servers.create!(name: "other-mcp",
                                                   url: "https://other.example.com/rpc", active: true)
    other_tool = other_server.mcp_tools.create!(name: "other_tool",
                                                 input_schema: { type: "object" }, active: true)

    # Stub OpenAI with a plain text response (no tools) — we expect llm.rb
    # to be called WITHOUT the foreign tool.
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: {
        id: "x", model: "gpt-5",
        choices: [ { index: 0, finish_reason: "stop",
                     message: { role: "assistant", content: "I have no tools." } } ],
        usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
      }.to_json
    )

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chats",
         params: { prompt: "use other tool", tool_ids: [ other_tool.id ] },
         headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["response"]["message"]).to eq("I have no tools.")
    # Never contacted the other user's MCP server.
    expect(WebMock).not_to have_requested(:post, "https://other.example.com/rpc")
  end
end
