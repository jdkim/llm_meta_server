require 'rails_helper'

RSpec.describe Api::ChatStreamsController, type: :controller do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }
  let(:model_name) { "llama3.2" }
  let(:model_id) { "llama3.2" }
  let(:uuid) { "ollama-local" }

  before do
    allow(controller).to receive(:current_user).and_return(user)
    allow(controller).to receive(:bearer_token).and_return(nil)
    allow(LlmModelMap).to receive(:fetch!).with(model_name).and_return(model_id)
  end

  describe "POST #create" do
    it "emits SSE deltas and a terminating done event" do
      allow(LlmRbFacade).to receive(:stream!) do |_, _, sink:, **|
        sink << "Hello"
        sink << ", world"
        "Hello, world"
      end

      post :create, params: { llm_api_key_uuid: uuid, model_name: model_name, prompt: "Hi" }

      expect(response).to have_http_status(:success)
      expect(response.headers["Content-Type"]).to start_with("text/event-stream")
      body = response.body
      expect(body).to include('data: {"delta":"Hello"}')
      expect(body).to include('data: {"delta":", world"}')
      expect(body).to include("event: done")
    end

    it "skips empty deltas" do
      allow(LlmRbFacade).to receive(:stream!) do |_, _, sink:, **|
        sink << ""
        sink << nil
        sink << "ok"
        "ok"
      end

      post :create, params: { llm_api_key_uuid: uuid, model_name: model_name, prompt: "Hi" }

      body = response.body
      expect(body.scan(/data: \{"delta":/).size).to eq(1)
      expect(body).to include('data: {"delta":"ok"}')
    end

    it "emits an error event when the facade raises" do
      allow(LlmRbFacade).to receive(:stream!).and_raise(ArgumentError, "bad input")

      post :create, params: { llm_api_key_uuid: uuid, model_name: model_name, prompt: "Hi" }

      expect(response.body).to include('event: error')
      expect(response.body).to include('"code":"argument_error"')
      expect(response.body).to include('"message":"bad input"')
    end

    it "passes generation_settings through to the facade verbatim (pass-through, any keys)" do
      allow(LlmRbFacade).to receive(:stream!).and_return("ok")

      post :create, params: {
        llm_api_key_uuid: uuid,
        model_name: model_name,
        prompt: "Hi",
        generation_settings: {
          temperature: 0.7,
          max_tokens: 1024,
          think: true,
          options: { num_ctx: 8192 }
        }
      }

      expect(LlmRbFacade).to have_received(:stream!) do |_, _, sink:, generation_params:, **|
        expect(sink).to be_a(SseWriter)
        expect(generation_params.keys).to contain_exactly(:temperature, :max_tokens, :think, :options)
        expect(generation_params[:options]).to include(:num_ctx)
      end
    end

    it "forwards a valid PDF document param through to the facade" do
      allow(LlmRbFacade).to receive(:stream!).and_return("ok")
      allow(LlmModelMap).to receive(:supports_vision?).with(model_name, llm_type: nil).and_return(true)

      post :create, params: {
        llm_api_key_uuid: uuid,
        model_name: model_name,
        prompt: "summarize",
        document: { mime: "application/pdf", data_b64: "JVBERi0" }
      }

      expect(LlmRbFacade).to have_received(:stream!) do |_, _, document:, **|
        expect(document).to eq(mime: "application/pdf", data_b64: "JVBERi0")
      end
    end

    it "rejects a non-PDF document mime with an error event" do
      allow(LlmRbFacade).to receive(:stream!).and_return("ok")

      post :create, params: {
        llm_api_key_uuid: uuid,
        model_name: model_name,
        prompt: "hi",
        document: { mime: "application/msword", data_b64: "AAAA" }
      }

      expect(response.body).to include('event: error')
      expect(response.body).to include('Unsupported document mime')
      expect(LlmRbFacade).not_to have_received(:stream!)
    end

    it "rejects an oversized document (>10 MB decoded) with an error event" do
      allow(LlmRbFacade).to receive(:stream!).and_return("ok")
      # Base64 encoding grows by 4/3; anything longer than that fraction of the
      # 10 MB cap trips the guard. Use a small margin so this doesn't hit
      # Rack's 4 MB query-body cap.
      oversize_b64 = "A" * (Api::ChatStreamsController::MAX_DOCUMENT_BYTES * 4 / 3 + 128)

      post :create, params: {
        llm_api_key_uuid: uuid,
        model_name: model_name,
        prompt: "hi",
        document: { mime: "application/pdf", data_b64: oversize_b64 }
      }, as: :json

      expect(response.body).to include('event: error')
      expect(response.body).to include('exceeds')
      expect(LlmRbFacade).not_to have_received(:stream!)
    end

    it "rejects a document when the selected model doesn't support vision (proxy for PDF)" do
      allow(LlmModelMap).to receive(:supports_vision?).with(model_name, llm_type: nil).and_return(false)

      post :create, params: {
        llm_api_key_uuid: uuid,
        model_name: model_name,
        prompt: "hi",
        document: { mime: "application/pdf", data_b64: "JVBERi0" }
      }

      expect(response.body).to include('event: error')
      expect(response.body).to include("doesn't support image or document")
    end

    it "silently drops a document entry with an empty data_b64 (no error, no forward)" do
      allow(LlmRbFacade).to receive(:stream!).and_return("ok")

      post :create, params: {
        llm_api_key_uuid: uuid,
        model_name: model_name,
        prompt: "hi",
        document: { mime: "application/pdf", data_b64: "" }
      }

      expect(LlmRbFacade).to have_received(:stream!) do |_, _, document:, **|
        expect(document).to be_nil
      end
      expect(response.body).not_to include('event: error')
    end

    it "emits a tool_calls event before deltas when the facade reports tool calls" do
      allow(LlmRbFacade).to receive(:stream!) do |_, _, sink:, on_tool_calls: nil, **|
        on_tool_calls.call([{ id: "c1", name: "do_thing", arguments: { q: 42 } }]) if on_tool_calls
        sink << "Result text"
        { message: "Result text", tool_calls: [{ id: "c1", name: "do_thing", arguments: { q: 42 } }] }
      end

      post :create, params: { llm_api_key_uuid: uuid, model_name: model_name, prompt: "Hi" }

      body = response.body
      tool_event_idx = body.index("event: tool_calls")
      delta_idx = body.index('data: {"delta":"Result text"}')
      done_idx = body.index("event: done")

      expect(tool_event_idx).not_to be_nil
      expect(delta_idx).not_to be_nil
      expect(done_idx).not_to be_nil
      expect(tool_event_idx).to be < delta_idx
      expect(delta_idx).to be < done_idx
      expect(body).to include('"name":"do_thing"')
      expect(body).to include('"q":42')
    end
  end
end
