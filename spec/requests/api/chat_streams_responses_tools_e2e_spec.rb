require "rails_helper"

# E2E for function tools on OpenAI's /v1/responses endpoint.
#
# The unit specs around LlmRbFacade's Responses tool loop stub
# `llm.responses.create`, so they prove the orchestration (which round sends
# what) but not the wire. Everything the loop leans on is upstream llm.rb code
# that was verified by reading its source: the tool schema it emits, the
# `function_call` output items it parses back, the `__tools__` handle that
# turns them into callable functions, the `function_call_output` items it
# submits, and the streaming parser that reassembles all of it.
#
# This drives the whole chain for real and stubs only the two upstream HTTP
# hops — OpenAI's Responses SSE stream and the MCP server's JSON-RPC.
RSpec.describe "POST .../chat_streams with tools on the Responses API (E2E)", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-rtool") }
  let(:good_token) { "tok" }
  let(:auth_headers) { { "Authorization" => "Bearer #{good_token}" } }

  let!(:openai_key) do
    user.llm_api_keys.create!(llm_type: "openai", description: "p",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-test"))
  end

  let(:mcp_url) { "https://mcp.example.com/jsonrpc" }
  let!(:mcp_server) { user.mcp_servers.create!(name: "test-mcp", url: mcp_url, active: true) }

  # One required parameter and one optional — the shape llm.rb's `strict: true`
  # would have made OpenAI reject outright.
  let!(:lookup_tool) do
    mcp_server.mcp_tools.create!(
      name: "find_ids",
      description: "Look up ids for terms",
      input_schema: {
        type: "object",
        properties: {
          labels: { type: "string", description: "comma-separated terms" },
          dictionary: { type: "string", description: "optional dictionary" }
        },
        required: [ "labels" ]
      },
      active: true
    )
  end

  before do
    allow(GoogleIdTokenVerifier).to receive(:verify_all)
      .with(good_token).and_return("sub" => user.google_id)
  end

  # --- OpenAI Responses SSE bodies -----------------------------------------

  def sse(events)
    events.map { |e| "event: #{e[:type]}\ndata: #{e.to_json}\n\n" }.join
  end

  # A round whose output is a single function_call item.
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

  # A round that reasons briefly and then answers in text.
  def answer_round(response_id:, reasoning:, text:)
    sse([
      { type: "response.created", response: { id: response_id, status: "in_progress" } },
      { type: "response.reasoning_summary_text.delta", delta: reasoning },
      { type: "response.output_item.added", output_index: 0,
        item: { type: "message", role: "assistant", content: [] } },
      { type: "response.content_part.added", output_index: 0, content_index: 0,
        part: { type: "output_text", text: "" } },
      { type: "response.output_text.delta", output_index: 0, content_index: 0, delta: text },
      { type: "response.completed", response: { id: response_id, status: "completed" } }
    ])
  end

  def stub_openai_rounds(*bodies)
    responses = bodies.map do |b|
      { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: b }
    end
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(*responses)
  end

  def stub_mcp_server(text: "HP:0001250, HP:0002069")
    stub_request(:post, mcp_url).to_return do |req|
      body = JSON.parse(req.body)
      case body["method"]
      when "initialize"
        { status: 200,
          headers: { "Content-Type" => "application/json", "mcp-session-id" => "sess-1" },
          body: { jsonrpc: "2.0", id: body["id"],
                  result: { protocolVersion: "2025-03-26",
                            serverInfo: { name: "test-mcp", version: "1.0.0" } } }.to_json }
      when "notifications/initialized"
        { status: 200, body: "", headers: {} }
      when "tools/call"
        { status: 200, headers: { "Content-Type" => "application/json" },
          body: { jsonrpc: "2.0", id: body["id"],
                  result: { content: [ { type: "text", text: text } ] } }.to_json }
      else
        { status: 200, headers: { "Content-Type" => "application/json" },
          body: { jsonrpc: "2.0", id: body["id"], result: {} }.to_json }
      end
    end
  end

  def post_stream!(prompt: "ids for seizure?")
    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chat_streams",
         params: { prompt: prompt, tool_ids: [ lookup_tool.id ] },
         headers: auth_headers
  end

  def openai_bodies
    reqs = []
    WebMock::RequestRegistry.instance.requested_signatures.hash.each_key do |sig|
      reqs << sig if sig.uri.to_s.include?("/v1/responses")
    end
    reqs.map { |r| JSON.parse(r.body) }
  end

  # -------------------------------------------------------------------------

  it "runs the tool and streams the answer, never touching chat completions" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "find_ids", arguments: %({"labels":"seizure"})),
      answer_round(response_id: "resp_2", reasoning: "checking the dictionary", text: "Found two ids.")
    )
    stub_mcp_server

    post_stream!

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Found two ids.")
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/responses").twice
    expect(WebMock).not_to have_requested(:post, "https://api.openai.com/v1/chat/completions")
  end

  # The bug that started this: OpenAI refuses function tools together with a
  # reasoning model's reasoning_effort on chat completions, so the tools have
  # to travel on this endpoint, in the Responses tool shape (flat `name`, not
  # nested under `function`).
  it "sends the tool schema in the Responses shape, without strict mode" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "find_ids", arguments: %({"labels":"seizure"})),
      answer_round(response_id: "resp_2", reasoning: "r", text: "done")
    )
    stub_mcp_server

    post_stream!

    first = openai_bodies.first
    tool  = first["tools"].first
    expect(tool["type"]).to eq("function")
    expect(tool["name"]).to eq("find_ids")
    expect(tool).not_to have_key("function")
    # strict: true would 400 here — `dictionary` is a property but not required.
    expect(tool["strict"]).to be_nil
    expect(tool.dig("parameters", "required")).to eq([ "labels" ])
    expect(tool.dig("parameters", "properties").keys).to contain_exactly("labels", "dictionary")
  end

  # The round-2 wire shape the loop depends on: results go up as
  # `function_call_output` items keyed by the call_id from round 1, and the
  # chain is carried by previous_response_id rather than a replayed transcript.
  it "submits the tool result as a function_call_output chained by previous_response_id" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "find_ids", arguments: %({"labels":"seizure"})),
      answer_round(response_id: "resp_2", reasoning: "r", text: "done")
    )
    stub_mcp_server(text: "HP:0001250")

    post_stream!

    second = openai_bodies.last
    expect(second["previous_response_id"]).to eq("resp_1")

    item = second["input"].find { |i| i["type"] == "function_call_output" }
    expect(item).to be_present
    expect(item["call_id"]).to eq("call_1")
    expect(item["output"]).to include("HP:0001250")
  end

  # The MCP server must receive the arguments the model actually chose,
  # decoded from the streamed `arguments` JSON string.
  it "passes the model's arguments through to the MCP tool" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1", name: "find_ids",
                      arguments: %({"labels":"seizure","dictionary":"HPO"})),
      answer_round(response_id: "resp_2", reasoning: "r", text: "done")
    )
    stub_mcp_server

    post_stream!

    expect(WebMock).to have_requested(:post, mcp_url).with { |req|
      body = JSON.parse(req.body)
      body["method"] == "tools/call" &&
        body.dig("params", "name") == "find_ids" &&
        body.dig("params", "arguments") == { "labels" => "seizure", "dictionary" => "HPO" }
    }
  end

  # Reasoning summaries are the reason these models are on this endpoint at
  # all; a tool round must not silence them.
  it "still streams reasoning summaries across a tool round" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "find_ids", arguments: %({"labels":"seizure"})),
      answer_round(response_id: "resp_2", reasoning: "weighing the two ids", text: "Found two.")
    )
    stub_mcp_server

    post_stream!

    expect(response.body).to include("thinking")
    expect(response.body).to include("weighing the two ids")
  end

  it "reports the executed call and its result to the client" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "find_ids", arguments: %({"labels":"seizure"})),
      answer_round(response_id: "resp_2", reasoning: "r", text: "done")
    )
    stub_mcp_server(text: "HP:0001250")

    post_stream!

    expect(response.body).to include("find_ids")
    expect(response.body).to include("HP:0001250")
  end

  # The Responses API can emit several function_call items in one round, and
  # the loop must run all of them and key each result back to its own call_id.
  # One round with two calls is not the same code path as two rounds.
  describe "parallel calls in one round" do
    def two_call_round
      sse([
        { type: "response.created", response: { id: "resp_1", status: "in_progress" } },
        { type: "response.output_item.added", output_index: 0,
          item: { type: "function_call", id: "fc_1", call_id: "call_a",
                  name: "find_ids", arguments: "" } },
        { type: "response.output_item.done", output_index: 0,
          item: { type: "function_call", id: "fc_1", call_id: "call_a",
                  name: "find_ids", arguments: %({"labels":"seizure"}) } },
        { type: "response.output_item.added", output_index: 1,
          item: { type: "function_call", id: "fc_2", call_id: "call_b",
                  name: "find_ids", arguments: "" } },
        { type: "response.output_item.done", output_index: 1,
          item: { type: "function_call", id: "fc_2", call_id: "call_b",
                  name: "find_ids", arguments: %({"labels":"ataxia"}) } },
        { type: "response.completed", response: { id: "resp_1", status: "completed" } }
      ])
    end

    it "runs both calls and returns one output item per call_id" do
      stub_openai_rounds(two_call_round, answer_round(response_id: "resp_2", reasoning: "r", text: "both done"))
      stub_mcp_server

      post_stream!

      expect(WebMock).to have_requested(:post, mcp_url)
        .with { |req| JSON.parse(req.body)["method"] == "tools/call" }.twice

      outputs = openai_bodies.last["input"].select { |i| i["type"] == "function_call_output" }
      expect(outputs.map { |o| o["call_id"] }).to contain_exactly("call_a", "call_b")
    end

    it "sends both calls' arguments, not the first one twice" do
      stub_openai_rounds(two_call_round, answer_round(response_id: "resp_2", reasoning: "r", text: "ok"))
      stub_mcp_server

      post_stream!

      labels = WebMock::RequestRegistry.instance.requested_signatures.hash.keys
        .select { |sig| sig.uri.to_s.include?("mcp.example.com") }
        .map { |sig| JSON.parse(sig.body) }
        .select { |b| b["method"] == "tools/call" }
        .map { |b| b.dig("params", "arguments", "labels") }
      expect(labels).to contain_exactly("seizure", "ataxia")
    end
  end

  # config/initializers/llm_unknown_tool_call.rb guards Message#functions
  # against a hallucinated tool name. It is endpoint-agnostic in principle,
  # but the Responses adapter builds tool_calls differently from the chat one,
  # so confirm the guard actually holds here rather than assuming it.
  it "survives a tool call naming a tool that was never sent" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "no_such_tool", arguments: %({"q":"x"})),
      answer_round(response_id: "resp_2", reasoning: "r", text: "recovered")
    )
    stub_mcp_server

    post_stream!

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("recovered")
    # The failure is fed back as that call's result so the model can correct
    # itself, rather than aborting the turn.
    item = openai_bodies.last["input"].find { |i| i["type"] == "function_call_output" }
    expect(item["output"]).to include("isError")
  end

  # adapt_tool parses each call's arguments eagerly, so a call cut off
  # mid-JSON raises inside `choices` rather than at the call site.
  it "reports a tool call whose arguments were cut off mid-JSON" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "find_ids", arguments: %({"labels":"seiz))
    )
    stub_mcp_server

    post_stream!

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("truncated_tool_call")
    expect(WebMock).not_to have_requested(:post, mcp_url)
  end

  # Gemini taught us that a model can go silent after a tool error; the notice
  # must reach the user regardless of what the model does next.
  it "surfaces an MCP tool error to the client" do
    stub_openai_rounds(
      tool_call_round(response_id: "resp_1", call_id: "call_1",
                      name: "find_ids", arguments: %({"labels":"seizure"})),
      answer_round(response_id: "resp_2", reasoning: "r", text: "")
    )
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
                  result: { isError: true,
                            content: [ { type: "text", text: "dictionary not found" } ] } }.to_json }
      end
    end

    post_stream!

    expect(response.body).to include("dictionary not found")
  end
end
