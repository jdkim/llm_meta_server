require "rails_helper"

# E2E for the client-orchestrated single-LLM-turn SSE endpoint. Stubs only the
# upstream provider HTTP and Google ID-token verification; ActionController::Live,
# SingleLlmCallSseWriter, LlmRbFacade#single_llm_turn!, and llm.rb's parsers all
# run for real.
#
# Locked-in wire-v2 framing:
#   - opening `event: phase\ndata: {"name":"thinking"}\n\n`
#   - text chunks as `event: text_delta\ndata: {"delta":"..."}\n\n`
#   - one `event: tool_call\ndata: {"tool_call":{...}}\n\n` per tool_call the LLM emits
#   - closing `event: done\ndata: {"content":"...","finish_reason":"..."}\n\n`
#   - `event: error\ndata: {...}\n\n` on failure (no `done`)
RSpec.describe "POST /api/llm_api_keys/:uuid/models/:name/single_llm_calls (E2E)", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-single") }
  let(:good_token) { "tok" }
  let(:auth_headers) { { "Authorization" => "Bearer #{good_token}" } }

  let!(:openai_key) do
    user.llm_api_keys.create!(llm_type: "openai", description: "p",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-test"))
  end

  before do
    allow(GoogleIdTokenVerifier).to receive(:verify_all)
      .with(good_token).and_return("sub" => user.google_id)
    # Pin gpt-5 to chat-completions to match the stubs below.
    allow(LlmModelMap).to receive(:endpoint_for).and_return("chat_completions")
  end

  # OpenAI chat-completions SSE body from a sequence of content chunks.
  def openai_sse_body(chunks, finish_reason: "stop")
    lines = chunks.each_with_index.map do |text, i|
      delta = (i == 0) ? { role: "assistant", content: text } : { content: text }
      "data: #{ { id: 'cc-1', model: 'gpt-5', choices: [ { index: 0, delta: delta } ] }.to_json }\n\n"
    end
    lines << "data: #{ { id: 'cc-1', model: 'gpt-5',
                          choices: [ { index: 0, delta: {}, finish_reason: finish_reason } ] }.to_json }\n\n"
    lines << "data: [DONE]\n\n"
    lines.join
  end

  def text_deltas(body)
    body.scan(/^event: text_delta\ndata: (\{.*"delta".*\})$/).flatten.map { |j| JSON.parse(j).fetch("delta") }
  end

  it "frames a text-only turn as phase → text_delta chunks → done{content, finish_reason}" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .with(headers: { "Authorization" => "Bearer sk-test" })
      .to_return(status: 200,
                 headers: { "Content-Type" => "text/event-stream" },
                 body: openai_sse_body([ "Hi", " there", "!" ]))

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/single_llm_calls",
         params: { messages: [ { role: "user", content: "hi" } ] }.to_json,
         headers: auth_headers.merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to start_with("text/event-stream")

    body = response.body
    expect(body).to match(/\Aevent: phase\ndata: \{"name":"thinking"\}\n\n/)
    expect(text_deltas(body)).to eq([ "Hi", " there", "!" ])

    done_line = body[/^event: done\ndata: (\{.*\})/, 1]
    expect(done_line).to be_present
    done = JSON.parse(done_line)
    expect(done["content"]).to eq("Hi there!")
    # finish_reason is best-effort — llm.rb's OpenAI streaming path doesn't
    # always surface it on the parsed choice object. Contract is that the
    # field is present in the done envelope, populated when the provider
    # exposes it.
    expect(done).to have_key("finish_reason")

    # No tool_calls in this turn.
    expect(body).not_to include("event: tool_call")

    # Upstream told to stream.
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").with { |req|
      JSON.parse(req.body)["stream"] == true
    }
  end

  it "emits one tool_call event per call the LLM requests, and does NOT execute them" do
    tool_call_chunk = {
      id: "cc-1", model: "gpt-5",
      choices: [ { index: 0, delta: {
        role: "assistant", content: nil,
        tool_calls: [
          { index: 0, id: "call_1", type: "function",
            function: { name: "add_dictionaries", arguments: '{"names":["uberon"]}' } }
        ]
      } } ]
    }
    body_lines = [
      "data: #{tool_call_chunk.to_json}\n\n",
      "data: #{ { id: 'cc-1', model: 'gpt-5',
                   choices: [ { index: 0, delta: {}, finish_reason: 'tool_calls' } ] }.to_json }\n\n",
      "data: [DONE]\n\n"
    ]

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200,
                 headers: { "Content-Type" => "text/event-stream" },
                 body: body_lines.join)

    # Register a stub MCP tool so the client can reference it by ID.
    mcp_server = user.mcp_servers.create!(name: "test", url: "http://mcp.test", active: true)
    tool = mcp_server.mcp_tools.create!(name: "add_dictionaries", description: "add",
                                        input_schema: { "type" => "object", "properties" => {} }, active: true)

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/single_llm_calls",
         params: {
           messages: [ { role: "user", content: "add uberon" } ],
           tool_ids: [ tool.id.to_s ]
         }.to_json,
         headers: auth_headers.merge("Content-Type" => "application/json")

    body = response.body
    expect(body).to include("event: tool_call")
    tc_line = body[/^event: tool_call\ndata: (\{.*\})/, 1]
    expect(tc_line).to be_present
    tc = JSON.parse(tc_line).fetch("tool_call")
    expect(tc["name"]).to eq("add_dictionaries")
    expect(tc["arguments"]).to include("names" => [ "uberon" ])

    # Critically: the hub did NOT call the MCP server's tools/call — that is
    # the client's job in the client-orchestrated flow.
    expect(WebMock).not_to have_requested(:post, "http://mcp.test")

    expect(body).to include("event: done")
  end

  it "emits event: error and skips done when the upstream call fails" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 429,
      headers: { "Content-Type" => "application/json" },
      body: { error: { message: "Rate limit reached" } }.to_json
    )

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/single_llm_calls",
         params: { messages: [ { role: "user", content: "hi" } ] }.to_json,
         headers: auth_headers.merge("Content-Type" => "application/json")

    body = response.body
    err_line = body[/^event: error\ndata: (\{.*\})/, 1]
    err = JSON.parse(err_line)
    expect(err["code"]).to eq("rate_limit")
    expect(body).not_to include("event: done")
  end

  it "emits a model_not_found error event when the model_name isn't in the catalog" do
    post "/api/llm_api_keys/#{openai_key.uuid}/models/not-a-real-model/single_llm_calls",
         params: { messages: [ { role: "user", content: "hi" } ] }.to_json,
         headers: auth_headers.merge("Content-Type" => "application/json")

    body = response.body
    err = JSON.parse(body[/^event: error\ndata: (\{.*\})/, 1])
    expect(err["code"]).to eq("model_not_found")
    expect(body).not_to include("event: done")
    expect(WebMock).not_to have_requested(:post, /openai\.com/)
  end
end
