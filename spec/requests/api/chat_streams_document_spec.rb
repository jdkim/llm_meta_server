require "rails_helper"

# Integration spec for the SSE streaming endpoint's document-input path.
# Parallels chat_streams_image_spec.rb: stubs at the service boundary
# (LlmRbFacade) since ActionController::Live streaming bodies don't play
# nicely with rack-test.
RSpec.describe "POST /api/llm_api_keys/:uuid/models/:name/chat_streams (document)", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-1") }
  let(:anthropic_key) {
    user.llm_api_keys.create!(llm_type: "anthropic", description: "personal",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-anth"))
  }
  let(:google_key) {
    user.llm_api_keys.create!(llm_type: "google", description: "personal",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "g-test"))
  }

  before do
    allow_any_instance_of(ApiController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApiController).to receive(:bearer_token).and_return("stub-token")
  end

  context "bearer-token path" do
    it "forwards a valid PDF document through to the facade for an Anthropic model" do
      captured_document = nil
      allow(LlmRbFacade).to receive(:stream!) do |_, _, sink:, document:, **|
        captured_document = document
        sink << "ok"
        "ok"
      end

      post "/api/llm_api_keys/#{anthropic_key.uuid}/models/claude-sonnet-4-6/chat_streams",
           params: { prompt: "summarize this paper", document: { mime: "application/pdf", data_b64: "JVBERi0x" } }

      expect(response).to have_http_status(:ok)
      expect(captured_document).to eq(mime: "application/pdf", data_b64: "JVBERi0x")
      expect(response.body).to include('data: {"delta":"ok"}')
    end

    it "forwards a valid PDF document through to the facade for a Gemini model" do
      captured_document = nil
      allow(LlmRbFacade).to receive(:stream!) do |_, _, sink:, document:, **|
        captured_document = document
        sink << "ok"
        "ok"
      end

      post "/api/llm_api_keys/#{google_key.uuid}/models/gemini-3-1-pro/chat_streams",
           params: { prompt: "extract the tables", document: { mime: "application/pdf", data_b64: "JVBERi0x" } }

      expect(response).to have_http_status(:ok)
      expect(captured_document).to eq(mime: "application/pdf", data_b64: "JVBERi0x")
    end

    it "rejects a document for a model that doesn't support vision (the PDF-capable proxy)" do
      allow(LlmModelMap).to receive(:supports_vision?).and_return(false)

      post "/api/llm_api_keys/#{anthropic_key.uuid}/models/claude-haiku-4-5/chat_streams",
           params: { prompt: "please", document: { mime: "application/pdf", data_b64: "JVBERi0x" } }

      expect(response.body).to include("event: error")
      expect(response.body).to include("Selected model doesn't support image or document input")
    end

    it "rejects a non-PDF mime type" do
      post "/api/llm_api_keys/#{anthropic_key.uuid}/models/claude-sonnet-4-6/chat_streams",
           params: { prompt: "hi", document: { mime: "text/plain", data_b64: "aGk=" } }

      expect(response.body).to include("event: error")
      expect(response.body).to include("Unsupported document mime")
    end

    it "silently drops a document entry with an empty data_b64 (no facade call, no error)" do
      allow(LlmRbFacade).to receive(:stream!) do |_, _, sink:, document:, **|
        expect(document).to be_nil
        sink << "ok"
        "ok"
      end

      post "/api/llm_api_keys/#{anthropic_key.uuid}/models/claude-sonnet-4-6/chat_streams",
           params: { prompt: "hi", document: { mime: "application/pdf", data_b64: "" } }

      expect(response).to have_http_status(:ok)
      expect(LlmRbFacade).to have_received(:stream!)
    end

    it "silently drops a document entry with an empty mime (no facade call, no error)" do
      allow(LlmRbFacade).to receive(:stream!) do |_, _, sink:, document:, **|
        expect(document).to be_nil
        sink << "ok"
        "ok"
      end

      post "/api/llm_api_keys/#{anthropic_key.uuid}/models/claude-sonnet-4-6/chat_streams",
           params: { prompt: "hi", document: { mime: "", data_b64: "JVBERi0x" } }

      expect(response).to have_http_status(:ok)
      expect(LlmRbFacade).to have_received(:stream!)
    end
  end

  context "provider gating" do
    it "rejects a document for an OpenAI model (llm_type not in DOCUMENT_CAPABLE_LLM_TYPES)" do
      openai_key = user.llm_api_keys.create!(llm_type: "openai", description: "personal",
                                             encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-oai"))
      # OpenAI vision models pass the vision gate, so the provider gate is the
      # only thing stopping a doomed PDF request.
      post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chat_streams",
           params: { prompt: "read this", document: { mime: "application/pdf", data_b64: "JVBERi0x" } }

      expect(response.body).to include("event: error")
      expect(response.body).to include("Anthropic and Gemini")
    end
  end

  context "anonymous (no bearer token) path" do
    before do
      allow_any_instance_of(ApiController).to receive(:current_user).and_return(nil)
      allow_any_instance_of(ApiController).to receive(:bearer_token).and_return(nil)
    end

    it "rejects a PDF for anonymous (Ollama-only) requests — llm.rb's Ollama adapter can't route PDFs" do
      ollama_meta = LlmModelMap.available_models_for("ollama").first["value"]

      post "/api/llm_api_keys/ollama-local/models/#{ollama_meta}/chat_streams",
           params: { prompt: "hi", document: { mime: "application/pdf", data_b64: "JVBERi0x" } }

      expect(response.body).to include("event: error")
      expect(response.body).to include("Anthropic and Gemini")
    end

    it "rejects a document for an anonymous non-vision model" do
      ollama_meta = LlmModelMap.available_models_for("ollama").first["value"]
      allow(LlmModelMap).to receive(:supports_vision?).and_return(false)

      post "/api/llm_api_keys/ollama-local/models/#{ollama_meta}/chat_streams",
           params: { prompt: "hi", document: { mime: "application/pdf", data_b64: "JVBERi0x" } }

      expect(response.body).to include("event: error")
      expect(response.body).to include("Selected model doesn't support image or document input")
    end
  end
end
