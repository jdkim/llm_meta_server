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

  it "marks favorited Ollama models with favorite: true and others with favorite: false" do
    # Pick the favorite + a sibling dynamically so this spec stays green
    # across catalog edits.
    catalog = LlmModelMap.available_models_for("ollama").map { |m| m["value"] }
    favorite_meta = catalog.first
    other_meta    = catalog[1] or skip "need at least two ollama models for this test"
    user.update!(favorite_model_meta_ids: [ favorite_meta ])

    get "/api/llms"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    ollama = body.fetch("llms").find { |l| (l["family"] || l[:family]) == "ollama" }
    expect(ollama).to be_present

    favorited = ollama["available_models"].find { |m| m["value"] == favorite_meta }
    other     = ollama["available_models"].find { |m| m["value"] == other_meta }
    expect(favorited["favorite"]).to be true
    expect(other["favorite"]).to be false
  end

  it "marks the user's default model with default: true and the rest with default: false" do
    catalog = LlmModelMap.available_models_for("ollama").map { |m| m["value"] }
    default_meta = catalog.first
    user.update!(default_model_meta_id: default_meta)

    get "/api/llms"
    body = JSON.parse(response.body)
    ollama = body.fetch("llms").find { |l| (l["family"] || l[:family]) == "ollama" }
    marked = ollama["available_models"].find { |m| m["value"] == default_meta }
    other  = ollama["available_models"].find { |m| m["value"] != default_meta }
    expect(marked["default"]).to be true
    expect(other["default"]).to be false
  end

  it "marks every model with default: false when the user has not set a default" do
    user.update!(default_model_meta_id: nil)
    get "/api/llms"
    ollama = JSON.parse(response.body)["llms"].find { |l| l["family"] == "ollama" }
    expect(ollama["available_models"].map { |m| m["default"] }.uniq).to eq([ false ])
  end

  it "includes supports_vision per model option (always a strict boolean)" do
    get "/api/llms"
    body = JSON.parse(response.body)
    ollama = body["llms"].find { |l| l["family"] == "ollama" }

    ollama["available_models"].each do |m|
      expect(m["supports_vision"]).to satisfy { |v| v == true || v == false },
        "#{m['value']} has non-boolean supports_vision: #{m['supports_vision'].inspect}"
    end
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
