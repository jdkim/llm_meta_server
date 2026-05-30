require "rails_helper"

# End-to-end integration test for the JSON chat endpoint. Drives the full
# stack — Devise/Google-ID-token auth → ApiController → ChatsController →
# LlmModelMap → LlmRbFacade → llm.rb provider → upstream HTTP — by stubbing
# only:
#
#   * `GoogleIdTokenVerifier.verify_all` (so we don't need a real Google
#     keyset to forge a token), and
#   * the upstream provider HTTP endpoint via WebMock.
#
# Everything in between executes for real, so the test pins the provider
# request shapes that llm.rb produces and the response envelope shape the
# controller renders back.
RSpec.describe "POST /api/llm_api_keys/:uuid/models/:name/chats", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-e2e") }
  let(:good_token) { "good-token" }
  let(:auth_headers) { { "Authorization" => "Bearer #{good_token}" } }

  before do
    allow(GoogleIdTokenVerifier).to receive(:verify_all)
      .with(good_token).and_return("sub" => user.google_id)
    allow(GoogleIdTokenVerifier).to receive(:verify_all)
      .with("bad-token")
      .and_raise(Google::Auth::IDTokens::VerificationError, "invalid signature")
  end

  describe "authentication" do
    # Note: an absent Authorization header is NOT a 401 — the controller has a
    # deliberate anonymous fallback path that routes to Ollama (which needs no
    # provider key). That path is exercised separately (in chat_streams).
    it "returns 401 when the bearer token fails verification" do
      post "/api/llm_api_keys/anything/models/qwen3-5-4b/chats",
           params: { prompt: "hi" },
           headers: { "Authorization" => "Bearer bad-token" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to include("error" => "Unauthorized")
    end

    it "returns 400 with a clear message when prompt is missing" do
      user.llm_api_keys.create!(llm_type: "openai", description: "p",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-test"))
      key = user.llm_api_keys.last
      post "/api/llm_api_keys/#{key.uuid}/models/gpt-5/chats",
           params: { not_prompt: "oops" }, headers: auth_headers
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("Parameter missing")
    end
  end

  describe "OpenAI provider" do
    let!(:openai_key) do
      user.llm_api_keys.create!(llm_type: "openai", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-test"))
    end

    it "decrypts the user's API key, forwards the prompt to OpenAI, and returns the assistant message" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .with(headers: { "Authorization" => "Bearer sk-test" })
        .to_return(
          status: 200,
          body: {
            id: "chatcmpl-x", model: "gpt-5",
            choices: [ { index: 0, message: { role: "assistant", content: "hello back" },
                         finish_reason: "stop" } ],
            usage: { prompt_tokens: 5, completion_tokens: 2, total_tokens: 7 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chats",
           params: { prompt: "hi there" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("response" => { "message" => "hello back" })

      expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").with { |req|
        b = JSON.parse(req.body)
        expect(b["model"]).to eq("gpt-5")
        # llm.rb sends content as an array of typed blocks rather than a bare string.
        expect(b["messages"].length).to eq(1)
        expect(b["messages"].first["role"]).to eq("user")
        text = b["messages"].first["content"].find { |c| c["type"] == "text" }
        expect(text["text"]).to eq("hi there")
        true
      }
    end

    it "returns 404 with a typed envelope when the model_name isn't in the catalog" do
      post "/api/llm_api_keys/#{openai_key.uuid}/models/not-a-real-model/chats",
           params: { prompt: "hi" }, headers: auth_headers

      expect(response).to have_http_status(:not_found)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Model not found")
      expect(body["message"]).to include("not-a-real-model")
      # Never reached the upstream.
      expect(WebMock).not_to have_requested(:post, /openai\.com/)
    end

    it "surfaces a 429 from OpenAI as a 429 with the rate-limit envelope" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 429,
        body: { error: { message: "Rate limit reached" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chats",
           params: { prompt: "hi" }, headers: auth_headers

      expect(response).to have_http_status(:too_many_requests)
      expect(JSON.parse(response.body)["error"]).to eq("LLM API Rate limit exceeded")
    end
  end

  describe "Anthropic provider" do
    let!(:anthropic_key) do
      user.llm_api_keys.create!(llm_type: "anthropic", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-anth"))
    end

    it "forwards via x-api-key, applies the max_tokens=8192 default, and returns the assistant text" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(headers: { "x-api-key" => "sk-anth", "anthropic-version" => "2023-06-01" })
        .to_return(
          status: 200,
          body: {
            id: "msg_x", model: "claude-opus-4-7", role: "assistant",
            content: [ { type: "text", text: "claude says hi" } ],
            stop_reason: "end_turn",
            usage: { input_tokens: 4, output_tokens: 3 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post "/api/llm_api_keys/#{anthropic_key.uuid}/models/claude-opus-4-7/chats",
           params: { prompt: "ping" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("response" => { "message" => "claude says hi" })

      expect(WebMock).to have_requested(:post, "https://api.anthropic.com/v1/messages").with { |req|
        b = JSON.parse(req.body)
        expect(b["model"]).to eq("claude-opus-4-7")
        expect(b["max_tokens"]).to eq(8192) # ANTHROPIC_DEFAULT_MAX_TOKENS
        expect(b["messages"].first["role"]).to eq("user")
        text = b["messages"].first["content"].find { |c| c["type"] == "text" }
        expect(text["text"]).to eq("ping")
        true
      }
    end

    it "honors an explicit max_tokens from the request body" do
      stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        status: 200,
        body: { id: "m", model: "claude-opus-4-7", role: "assistant",
                content: [ { type: "text", text: "ok" } ],
                stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      post "/api/llm_api_keys/#{anthropic_key.uuid}/models/claude-opus-4-7/chats",
           params: { prompt: "ping", max_tokens: 256 }.to_json,
           headers: auth_headers.merge("Content-Type" => "application/json")

      expect(WebMock).to have_requested(:post, "https://api.anthropic.com/v1/messages").with { |req|
        expect(JSON.parse(req.body)["max_tokens"]).to eq(256)
        true
      }
    end
  end

  describe "Google Gemini provider" do
    let!(:google_key) do
      user.llm_api_keys.create!(llm_type: "google", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "g-key"))
    end

    it "POSTs to generateContent with the api key in the query, sends a user-role content turn, and returns the model text" do
      stub_request(:post, %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-3-pro-preview:generateContent\?key=g-key})
        .to_return(
          status: 200,
          body: {
            candidates: [
              { content: { parts: [ { text: "gemini says hi" } ], role: "model" },
                finishReason: "STOP", index: 0 }
            ],
            usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: 7 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post "/api/llm_api_keys/#{google_key.uuid}/models/gemini-3-pro/chats",
           params: { prompt: "hi gemini" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("response" => { "message" => "gemini says hi" })

      expect(WebMock).to have_requested(:post, /generateContent\?key=g-key/).with { |req|
        b = JSON.parse(req.body)
        expect(b["contents"]).to be_an(Array)
        expect(b["contents"].first["role"]).to eq("user")
        text_part = b["contents"].first["parts"].find { |p| p["text"] }
        expect(text_part["text"]).to eq("hi gemini")
        true
      }
    end
  end
end
