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

  it "declares client-supplied local_tools to the LLM as functions with the given schema" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200,
                 headers: { "Content-Type" => "text/event-stream" },
                 body: openai_sse_body([ "acknowledged" ]))

    input_schema = {
      "type" => "object",
      "properties" => { "names" => { "type" => "array", "items" => { "type" => "string" } } },
      "required" => [ "names" ]
    }

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/single_llm_calls",
         params: {
           messages: [ { role: "user", content: "hi" } ],
           local_tools: [ {
             name: "add_dictionaries",
             description: "Add the named dictionaries to the current selection.",
             input_schema: input_schema
           } ]
         }.to_json,
         headers: auth_headers.merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:ok)

    # The upstream OpenAI call MUST carry the local_tools schema in its `tools`
    # array — that's how the LLM learns the function exists.
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").with { |req|
      req_body = JSON.parse(req.body)
      tool_entry = (req_body["tools"] || []).find do |t|
        t.dig("function", "name") == "add_dictionaries" || t["name"] == "add_dictionaries"
      end
      # OpenAI's chat-completions wire format nests the function under
      # `function: {name, description, parameters}`. llm.rb serializes
      # LLM::Function that way — we assert on the nested shape.
      tool_entry && tool_entry.dig("function", "description")&.include?("Add the named dictionaries")
    }
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

  # Found in end-to-end testing against qwen3.8: the turn after a page action
  # re-emitted that action as a fresh tool_call. The session is seeded with
  # the browser's history, and the reported calls came from every assistant
  # message in it — so a call the browser had already run came back, and the
  # widget would have run it again (e.g. adding the dictionary twice).
  it "does not re-emit a tool_call that is already in the history" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200,
                 headers: { "Content-Type" => "text/event-stream" },
                 body: openai_sse_body([ "Added uberon." ]))

    history = [
      { role: "user", content: "Add the uberon dictionary." },
      { role: "assistant", content: "",
        tool_calls: [ { id: "call_1", name: "add_dictionaries", arguments: { names: [ "uberon" ] } } ] },
      { role: "tool", tool_call_id: "call_1", name: "add_dictionaries",
        content: { ok: true }.to_json }
    ]
    local_tools = [ { name: "add_dictionaries", description: "Add dictionaries by name.",
                      input_schema: { type: "object",
                                      properties: { names: { type: "array", items: { type: "string" } } },
                                      required: [ "names" ] } } ]

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/single_llm_calls",
         params: { messages: history, local_tools: local_tools }.to_json,
         headers: auth_headers.merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:ok)
    expect(text_deltas(response.body).join).to eq("Added uberon.")
    expect(response.body).not_to include("event: tool_call"),
      "the history's call must not come back as a new one"
  end

  # Regression: `selected_tools` passed `viewer: current_user` unguarded, and
  # ApiController#current_user raises "Token is missing" without a bearer. The
  # `return [] if tool_ids.blank?` line above hid it — anonymous chat worked
  # until the visitor selected a hub-registered tool, then every turn 400'd.
  # Production showed exactly that asymmetry: the same anonymous visitor got
  # 200 OK for a plain message and "Token is missing" 80 seconds later with
  # tool_ids present.
  describe "tool lookup viewer" do
    let(:ollama_model) { LlmModelMap.available_models_for("ollama").first["value"] }

    let!(:anon_tool) do
      server = user.mcp_servers.create!(name: "togo", url: "http://mcp.test/rpc", active: true,
                                        public: true, public_to_anonymous: true)
      server.mcp_tools.create!(name: "search", description: "d",
                               input_schema: { "type" => "object", "properties" => {} },
                               active: true)
    end

    before do
      allow(LlmRbFacade).to receive(:single_llm_turn!)
        .and_return(content: "ok", finish_reason: "stop", tool_calls: [])
    end

    it "looks tools up as an anonymous viewer when there is no bearer token" do
      expect(McpTool).to receive(:lookup).with(anything, viewer: nil).and_call_original

      post "/api/llm_api_keys/ollama-local/models/#{ollama_model}/single_llm_calls",
           params: { messages: [ { role: "user", content: "hi" } ], tool_ids: [ anon_tool.id ] }

      expect(response.body).not_to include("Token is missing")
    end

    it "still looks tools up as the signed-in user when a bearer token is present" do
      expect(McpTool).to receive(:lookup).with(anything, viewer: user).and_call_original

      post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/single_llm_calls",
           params: { messages: [ { role: "user", content: "hi" } ], tool_ids: [ anon_tool.id ] },
           headers: auth_headers

      expect(response.body).not_to include("Token is missing")
    end
  end

  # The throttle's logic is unit-tested; what is untested is the WIRING. The
  # check! call and its rescue were both inserted by hand into an existing
  # method, and a misplaced rescue would still throttle — it would just report
  # "internal_error" instead of telling the caller they hit the free limit and
  # can supply their own key. Every unit test stays green through that.
  describe "free-model throttling" do
    let(:free_model_id) { "openai.gpt-oss-120b-1:0" }

    around do |example|
      was = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new   # test env is :null_store
      example.run
      Rails.cache = was
    end

    before do
      allow(LlmModelMap).to receive(:fetch!).and_return(free_model_id)
      allow(LlmModelMap).to receive(:free_access_model?).and_return(true)
      allow(LlmModelMap).to receive(:ollama_model?).and_return(true)   # keeps execution local/cheap
    end

    def post_free_turn
      post "/api/llm_api_keys/free-models/models/gpt-oss-120b/single_llm_calls",
           params: { messages: [ { role: "user", content: "hi" } ] }.to_json,
           headers: { "Content-Type" => "application/json", "Origin" => "https://demo.example" }
    end

    it "reports the limit as a rate_limit error event, not internal_error" do
      allow(FreeModelThrottle).to receive(:check!)
        .and_raise(FreeModelThrottle::Exceeded, "Free-model limit reached (#{FreeModelThrottle::LIMIT} requests per #{FreeModelThrottle::WINDOW / 60} minutes). " \
                                                "Add your own API key to continue.")

      post_free_turn

      expect(response.body).to include("event: error")
      expect(response.body).not_to include("event: done")
      payload = response.body[/^event: error\ndata: (\{.*\})$/, 1]
      expect(payload).to be_present
      parsed = JSON.parse(payload)
      expect(parsed["code"]).to eq("rate_limit")
      expect(parsed["message"]).to include("Add your own API key")
    end

    it "consults the throttle with the request's origin and the resolved model" do
      expect(FreeModelThrottle).to receive(:check!)
        .with(hash_including(model_id: free_model_id, llm_api_key: nil,
                             origin: "https://demo.example"))
        .and_raise(FreeModelThrottle::Exceeded, "nope")

      post_free_turn

      expect(response.body).to include("rate_limit")
    end
  end
end
