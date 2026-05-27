require "rails_helper"

# Integration spec for the /models web UI. Drives the full Rails stack
# (routing + Devise + view rendering) with a signed-in test user.
RSpec.describe "Favorite models management", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "u@example.com", google_id: "g-1") }

  before { sign_in user }

  describe "GET /models" do
    it "renders with the ollama section visible when the user has no API keys (ollama needs none)" do
      get "/models"
      expect(response).to have_http_status(:ok)
      # Section headers are lowercase in markup (CSS `capitalize` styles them).
      expect(response.body).to include(">ollama<")
    end

    it "lists only providers the user has API keys for plus ollama" do
      # User registers an OpenAI key — should see OpenAI + Ollama, not Anthropic/Google.
      user.llm_api_keys.create!(llm_type: "openai", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-test"))

      get "/models"
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include(">openai<")
      expect(body).to include(">ollama<")
      expect(body).not_to include(">anthropic<")
      expect(body).not_to include(">google<")
    end

    it "marks favorited models with the filled star (★)" do
      user.update!(favorite_model_meta_ids: [ "qwen3-5-4b" ])
      get "/models"
      # Look for the filled star adjacent to qwen3-5-4b
      expect(response.body).to match(/★[^☆]*qwen3-5-4b/m)
    end
  end

  describe "PATCH /models/:id/toggle_favorite" do
    it "adds a model to favorites and redirects with a notice" do
      patch "/models/qwen3-5-4b/toggle_favorite"
      expect(response).to redirect_to(models_path)
      follow_redirect!
      expect(response.body).to include("Added to favorites.")
      expect(user.reload.favorite_model_meta_ids).to include("qwen3-5-4b")
    end

    it "removes an existing favorite and redirects with a notice" do
      user.update!(favorite_model_meta_ids: [ "qwen3-5-4b" ])
      patch "/models/qwen3-5-4b/toggle_favorite"
      expect(response).to redirect_to(models_path)
      follow_redirect!
      expect(response.body).to include("Removed from favorites.")
      expect(user.reload.favorite_model_meta_ids).not_to include("qwen3-5-4b")
    end

    it "rejects an unknown meta_id" do
      patch "/models/totally-fake-model/toggle_favorite"
      expect(response).to redirect_to(models_path)
      follow_redirect!
      expect(response.body).to include("Unknown model.")
    end
  end
end
