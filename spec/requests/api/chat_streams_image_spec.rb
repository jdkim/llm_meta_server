require "rails_helper"

# Integration spec for the SSE streaming endpoint's image-input + image-gen
# routing. Stubs at the service boundary (LlmRbFacade / ImageGenerationService)
# rather than at the provider HTTP layer because Rack's test driver doesn't
# play well with ActionController::Live streaming bodies.
RSpec.describe "POST /api/llm_api_keys/:uuid/models/:name/chat_streams", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-1") }
  let(:openai_key) {
    user.llm_api_keys.create!(llm_type: "openai", description: "personal",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-test"))
  }
  let(:google_key) {
    user.llm_api_keys.create!(llm_type: "google", description: "personal",
                              encryptable_api_key: EncryptableApiKey.new(plain_api_key: "g-test"))
  }

  before do
    allow_any_instance_of(ApiController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApiController).to receive(:bearer_token).and_return("stub-token")
  end

  context "vision-gating" do
    it "rejects image input for a model that doesn't support vision" do
      # Force the no-vision branch via stub — every current ollama catalog
      # entry has supports_vision: true, so the gating rejection can't be
      # exercised with a real meta_id alone.
      ollama_meta = LlmModelMap.available_models_for("ollama").first["value"]
      allow(LlmModelMap).to receive(:supports_vision?).and_return(false)

      post "/api/llm_api_keys/ollama-local/models/#{ollama_meta}/chat_streams",
           params: { prompt: "hi", image: { mime: "image/png", data_b64: "AAA" } }

      expect(response.body).to include("event: error")
      expect(response.body).to include("Selected model doesn't support image input")
    end

    it "accepts image input for a vision-capable model" do
      allow(LlmRbFacade).to receive(:stream!) do |_, _, sink:, image:, **|
        expect(image).to eq(mime: "image/png", data_b64: "AAA")
        sink << "ok"
        "ok"
      end

      post "/api/llm_api_keys/#{openai_key.uuid}/models/gpt-5/chat_streams",
           params: { prompt: "describe this", image: { mime: "image/png", data_b64: "AAA" } }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data: {"delta":"ok"}')
      expect(LlmRbFacade).to have_received(:stream!)
    end
  end

  context "image-gen routing" do
    it "routes image-generation models to ImageGenerationService, forwarding the attached image" do
      allow(ImageGenerationService).to receive(:generate!) do |model_id:, prompt:, llm_api_key:, image_context:, image:|
        expect(model_id).to eq("gemini-2.5-flash-image")
        expect(image).to eq(mime: "image/png", data_b64: "BBB")
        "![](data:image/png;base64,GENERATED)"
      end

      post "/api/llm_api_keys/#{google_key.uuid}/models/gemini-2-5-flash-image/chat_streams",
           params: { prompt: "make it red", image: { mime: "image/png", data_b64: "BBB" } }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("![](data:image/png;base64,GENERATED)")
      expect(response.body).to include("event: done")
      expect(ImageGenerationService).to have_received(:generate!)
    end
  end

  context "anonymous (no bearer token) path" do
    before do
      allow_any_instance_of(ApiController).to receive(:current_user).and_return(nil)
      allow_any_instance_of(ApiController).to receive(:bearer_token).and_return(nil)
    end

    it "rejects image input for an anonymous non-vision model" do
      ollama_meta = LlmModelMap.available_models_for("ollama").first["value"]
      allow(LlmModelMap).to receive(:supports_vision?).and_return(false)

      post "/api/llm_api_keys/ollama-local/models/#{ollama_meta}/chat_streams",
           params: { prompt: "hi", image: { mime: "image/png", data_b64: "AAA" } }

      expect(response.body).to include("event: error")
      expect(response.body).to include("Selected model doesn't support image input")
    end
  end
end
