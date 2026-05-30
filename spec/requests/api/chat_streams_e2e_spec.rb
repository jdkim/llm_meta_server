require "rails_helper"

# E2E for the SSE streaming endpoint. Stubs only the upstream provider HTTP
# (OpenAI's chat-completions SSE stream) and Google ID-token verification;
# everything between — ActionController::Live, SseWriter, LlmRbFacade, llm.rb's
# StreamParser + EventStream::Parser — runs for real.
#
# The locked-in contract is the framing the test_service frontend depends on:
#   - opening `event: phase\ndata: {"name":"thinking"}\n\n`
#   - one `data: {"delta":"..."}\n\n` per content chunk
#   - closing `event: done\ndata: {}\n\n`
#   - `event: error\ndata: {...}\n\n` on failures (no `done`)
RSpec.describe "POST /api/llm_api_keys/:uuid/models/:name/chat_streams (E2E)", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-sse") }
  let(:good_token) { "tok" }
  let(:auth_headers) { { "Authorization" => "Bearer #{good_token}" } }

  let!(:openai_key) do
    user.llm_api_keys.create!(llm_type: "openai", description: "p",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-test"))
  end

  before do
    allow(GoogleIdTokenVerifier).to receive(:verify_all)
      .with(good_token).and_return("sub" => user.google_id)
  end

  # Build an OpenAI SSE response body from a sequence of content chunks.
  # Adds the [DONE] sentinel that OpenAI sends at the end.
  def openai_sse_body(chunks)
    lines = []
    chunks.each_with_index do |text, i|
      delta = (i == 0) ? { role: "assistant", content: text } : { content: text }
      lines << "data: #{ { id: 'cc-1', model: 'gpt-5',
                            choices: [ { index: 0, delta: delta } ] }.to_json }\n\n"
    end
    lines << "data: #{ { id: 'cc-1', model: 'gpt-5',
                          choices: [ { index: 0, delta: {}, finish_reason: 'stop' } ],
                          usage: { prompt_tokens: 3, completion_tokens: 3, total_tokens: 6 } }.to_json }\n\n"
    lines << "data: [DONE]\n\n"
    lines.join
  end

  # Extract just the `data: {...}` content deltas from the streamed body in order.
  def collect_deltas(body)
    body.scan(/^data: (\{.*"delta".*\})$/).flatten.map { |j| JSON.parse(j).fetch("delta") }
  end

  it "frames an OpenAI text stream as phase → deltas → done" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .with(headers: { "Authorization" => "Bearer sk-test" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "text/event-stream" },
        body: openai_sse_body([ "Hello", " ", "world", "!" ])
      )

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chat_streams",
         params: { prompt: "hi" }, headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to start_with("text/event-stream")
    expect(response.headers["Cache-Control"]).to eq("no-cache")
    expect(response.headers["X-Accel-Buffering"]).to eq("no")

    body = response.body

    # Opening phase frame.
    expect(body).to match(/\Aevent: phase\ndata: \{"name":"thinking"\}\n\n/)

    # Content deltas arrived as separate SSE data frames, in order, with no chunks lost.
    expect(collect_deltas(body)).to eq([ "Hello", " ", "world", "!" ])

    # Closing done frame.
    expect(body).to end_with("event: done\ndata: {}\n\n")

    # Upstream was instructed to stream.
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").with { |req|
      JSON.parse(req.body)["stream"] == true
    }
  end

  it "wraps the assistant's bytes verbatim in the {delta:} envelope (no transformation)" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 200, headers: { "Content-Type" => "text/event-stream" },
      body: openai_sse_body([ "line1\n", "with \"quotes\" and emoji 🚀" ])
    )

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chat_streams",
         params: { prompt: "go" }, headers: auth_headers

    deltas = collect_deltas(response.body)
    expect(deltas.join).to eq("line1\nwith \"quotes\" and emoji 🚀")
  end

  it "emits event: error and skips done when the upstream call fails" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 429,
      headers: { "Content-Type" => "application/json" },
      body: { error: { message: "Rate limit reached" } }.to_json
    )

    post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chat_streams",
         params: { prompt: "hi" }, headers: auth_headers

    body = response.body
    # Phase opener still appears (always emitted before the upstream call).
    expect(body).to include("event: phase")
    # Error event carries the code + message.
    expect(body).to match(/^event: error$/)
    err_line = body[/^event: error\ndata: (\{.*\})/, 1]
    expect(err_line).to be_present
    err = JSON.parse(err_line)
    expect(err["code"]).to eq("rate_limit")
    # Done is NOT sent when the body errored.
    expect(body).not_to include("event: done")
  end

  it "emits an argument_error event when the model can't process an attached image" do
    # qwen3-5-4b is text-only (ollama family). Use an unknown uuid so the
    # controller falls back to the ollama llm_type when looking up the model.
    post "/api/llm_api_keys/ollama-local/models/qwen3-5-4b/chat_streams",
         params: { prompt: "describe", image: { mime: "image/png", data_b64: "AAA" } },
         headers: auth_headers

    body = response.body
    expect(body).to include("event: phase")
    expect(body).to match(/^event: error$/)
    err = JSON.parse(body[/^event: error\ndata: (\{.*\})/, 1])
    expect(err["code"]).to eq("argument_error")
    expect(err["message"]).to include("doesn't support image input")
    expect(body).not_to include("event: done")
    # No upstream call happened — vision-gating ran first.
    expect(WebMock).not_to have_requested(:post, /openai\.com/)
  end
end
