require "rails_helper"
require Rails.root.join("spec/support/click_path")

# End-to-end click-paths through the admin UI.
#
# These follow the links the page renders and submit the forms it offers,
# rather than posting hand-written params. That distinction is the point:
# every bug found in this UI so far was a handoff — one screen producing
# something the next screen refused — and hand-written params hide exactly
# that class of failure.
RSpec.describe "Admin UI click-paths", type: :request do
  include Devise::Test::IntegrationHelpers
  include ClickPath

  let(:user) { User.create!(email: "op@example.com", google_id: "g-op") }

  before do
    allow(User).to receive(:super_user_emails).and_return([ user.email ])
    sign_in user
    Rails.cache.clear
    stub_request(:get, PricingReference::LITELLM_URL).to_return(status: 200, body: {
      "gpt-9.9"                     => { "input_cost_per_token" => 3.0e-6, "output_cost_per_token" => 15.0e-6 },
      "gemini-img.9"                => { "output_cost_per_image" => 0.0336 },
      "gpt-5.5-pro"                 => { "input_cost_per_token" => 30.0e-6, "output_cost_per_token" => 180.0e-6 }
    }.to_json)
    stub_request(:get, PricingReference::OPENROUTER_URL).to_return(status: 200, body: { "data" => [] }.to_json)
  end

  describe "discover a model, then add it" do
    it "adds a chat model by submitting exactly what the form offers" do
      ModelCatalogCheck.record!(provider: "openai", new_in_provider: [
        { "api_id" => "gpt-9.9", "input" => 3.0, "output" => 15.0 }
      ])

      get admin_models_path
      click_link(/gpt-9\.9/)          # the candidate link the page rendered
      expect(response).to have_http_status(:ok)

      submit_rendered_form(containing: "llm_model")   # verbatim, no invented values

      expect(response).to redirect_to(admin_models_path)
      expect(LlmModelMap.catalog.dig("openai", "gpt-9-9", :api_id)).to eq("gpt-9.9")
    end

    it "adds an image model — the form must not offer values it will reject" do
      # Regression: per_image pricing was pre-filled while `kind` stayed blank,
      # so validation demanded input/output and the form refused its own offer.
      ModelCatalogCheck.record!(provider: "google", new_in_provider: [
        { "api_id" => "gemini-img.9", "input" => nil, "output" => nil }
      ])

      get admin_models_path
      click_link(/gemini-img\.9/)
      submit_rendered_form(containing: "llm_model")

      expect(response).to redirect_to(admin_models_path)
      expect(LlmModelMap.catalog.dig("google", "gemini-img-9", :kind)).to eq(:image)
    end

    it "does not advertise tool calling on an image generator" do
      # The form defaults both capability boxes on, which is right for a chat
      # model and wrong for an image one.
      ModelCatalogCheck.record!(provider: "google", new_in_provider: [ { "api_id" => "gemini-img.9" } ])

      get admin_models_path
      click_link(/gemini-img\.9/)
      submit_rendered_form(containing: "llm_model")

      added = LlmModel.find_by(name: "gemini-img-9")
      expect(added.kind).to eq("image")
      expect(added.supports_tools).to be(false)
    end

    it "stops advertising the model once it has been added" do
      ModelCatalogCheck.record!(provider: "openai", new_in_provider: [
        { "api_id" => "gpt-9.9", "input" => 3.0, "output" => 15.0 }
      ])

      get admin_models_path
      click_link(/gpt-9\.9/)
      submit_rendered_form(containing: "llm_model")
      get admin_models_path

      expect(response.body).not_to include("available but not in the catalog")
    end
  end

  describe "open a model for editing and save it unchanged" do
    # A round-trip: whatever the form renders must be acceptable back. This is
    # the cheapest guard against a field the form shows but the model rejects.
    %w[gpt-5 gemini-3-pro-image qwen3-6-35b].each do |meta_id|
      it "round-trips #{meta_id} without the form offering something invalid" do
        model = LlmModel.find_by(name: meta_id)

        get edit_admin_model_path(model)
        expect(response).to have_http_status(:ok)

        submit_rendered_form(containing: "llm_model")

        expect(response).to redirect_to(admin_models_path)
        expect(model.reload).to be_valid
      end
    end
  end

  describe "correct a drifted price from the panel" do
    it "applies the reference and clears the row" do
      pro = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5-5-pro")
      pro.update!(pricing: { "input" => 5.0, "output" => 40.0 })

      post check_prices_admin_models_path
      get admin_models_path
      expect(response.body).to include("differ from the public references")

      submit_rendered_form(containing: "_method")   # the "Use reference" button_to
      get admin_models_path

      expect(pro.reload.pricing).to include("input" => 30.0, "output" => 180.0)
      expect(response.body).not_to include("differ from the public references")
    end
  end

  describe "navigation" do
    it "reaches every admin section from the dashboard nav" do
      get admin_path

      [ "Models", "MCP servers", "Users", "Dashboard" ].each do |label|
        click_nav(label)
        expect(response).to have_http_status(:ok), "#{label} did not render"
      end
    end
  end
end
