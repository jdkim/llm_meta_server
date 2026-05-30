require "rails_helper"

# Integration spec for /api/llms — the catalog endpoint the test_service
# polls. Verifies each model carries a `favorite` boolean per the calling
# user's stored favorites.
RSpec.describe "GET /api/llms", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-1") }

  before do
    # Bypass Google-ID-token verification at the ApiController layer; just
    # have current_user resolve to our test user.
    allow_any_instance_of(ApiController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApiController).to receive(:bearer_token).and_return("stub-token")
  end

  it "marks favorited Ollama models with favorite: true" do
    user.update!(favorite_model_meta_ids: [ "qwen3-5-4b" ])

    get "/api/llms"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    ollama = body.fetch("llms").find { |l| (l["family"] || l[:family]) == "ollama" }
    expect(ollama).to be_present

    qwen = ollama["available_models"].find { |m| m["value"] == "qwen3-5-4b" }
    other = ollama["available_models"].find { |m| m["value"] == "qwen3-5-9b" }
    expect(qwen["favorite"]).to be true
    expect(other["favorite"]).to be false
  end

  it "includes supports_vision per model option" do
    get "/api/llms"
    body = JSON.parse(response.body)
    ollama = body["llms"].find { |l| l["family"] == "ollama" }

    by_value = ollama["available_models"].to_h { |m| [ m["value"], m["supports_vision"] ] }
    expect(by_value["qwen3-6-35b"]).to be true
    expect(by_value["qwen3-5-4b"]).to be false
  end

  context "anonymous (no Authorization header)" do
    before do
      # Undo the global stubs so we test the real anonymous path.
      allow_any_instance_of(ApiController).to receive(:current_user).and_call_original
      allow_any_instance_of(ApiController).to receive(:bearer_token).and_call_original
    end

    it "still returns the Ollama family so guest users can render the LLM picker" do
      get "/api/llms"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      families = body["llms"].map { |l| l["family"] }
      expect(families).to include("ollama")
      ollama = body["llms"].find { |l| l["family"] == "ollama" }
      expect(ollama["available_models"]).to be_present
      # No user → every model has favorite: false.
      expect(ollama["available_models"].map { |m| m["favorite"] }.uniq).to eq([ false ])
    end
  end
end
