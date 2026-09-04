require "rails_helper"

# The service-management UI is gated on super_user? — deliberately the same
# gate as the rest of /admin, so the operator never has to switch accounts.
RSpec.describe "Admin service-management UI", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user)  { User.create!(email: "op@example.com", google_id: "g-op") }
  let(:other) { User.create!(email: "plain@example.com", google_id: "g-plain") }

  def as_super_user
    allow(User).to receive(:super_user_emails).and_return([ user.email ])
    sign_in user
  end

  describe "access control" do
    it "404s for a signed-in non-super-user, so the section is not leaked" do
      allow(User).to receive(:super_user_emails).and_return([])
      sign_in other

      get admin_models_path
      expect(response).to have_http_status(:not_found)
    end

    it "redirects an anonymous visitor to sign in" do
      get admin_models_path
      expect(response).to have_http_status(:redirect)
    end

    %i[admin_models_path admin_mcp_servers_path admin_users_path].each do |route|
      it "renders #{route} for a super_user" do
        as_super_user
        get send(route)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "catalog editing" do
    let!(:llm) { Llm.find_by(family: "openai") }

    it "adds a model and makes it visible to LlmModelMap without a restart" do
      as_super_user

      post admin_models_path, params: { llm_model: {
        llm_id: llm.id, name: "gpt-9-test", api_id: "gpt-9-test", display_name: "GPT 9 Test",
        supports_vision: "1", supports_tools: "1", active: "1",
        pricing_json: '{"input":1.0,"output":2.0,"reviewed_at":"2026-09-02"}', defaults_json: "{}"
      } }

      expect(response).to redirect_to(admin_models_path)
      expect(LlmModelMap.catalog.dig("openai", "gpt-9-test", :api_id)).to eq("gpt-9-test")
    end

    it "rejects a meta_id that is not URL-safe rather than corrupting routes" do
      as_super_user

      post admin_models_path, params: { llm_model: {
        llm_id: llm.id, name: "gpt-9.5", api_id: "gpt-9.5", display_name: "X",
        pricing_json: "{}", defaults_json: "{}"
      } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(LlmModelMap.catalog["openai"]).not_to have_key("gpt-9.5")
    end

    it "refuses a chargeable model with no prices, rather than billing it as free" do
      as_super_user

      post admin_models_path, params: { llm_model: {
        llm_id: llm.id, name: "gpt-unpriced", api_id: "gpt-unpriced", display_name: "Unpriced",
        pricing_json: "{}", defaults_json: "{}"
      } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(LlmModelMap.catalog["openai"]).not_to have_key("gpt-unpriced")
    end

    it "refuses a zero price — it looks set but bills nothing" do
      as_super_user

      post admin_models_path, params: { llm_model: {
        llm_id: llm.id, name: "gpt-zero", api_id: "gpt-zero", display_name: "Zero",
        pricing_json: '{"input":0,"output":0}', defaults_json: "{}"
      } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(LlmModelMap.catalog["openai"]).not_to have_key("gpt-zero")
    end

    it "allows a local (ollama) model with no pricing — it is free by nature" do
      as_super_user
      ollama = Llm.find_by(family: "ollama")

      post admin_models_path, params: { llm_model: {
        llm_id: ollama.id, name: "llama-test", api_id: "llama:test", display_name: "Llama Test",
        active: "1", pricing_json: "{}", defaults_json: "{}"
      } }

      expect(response).to redirect_to(admin_models_path)
      expect(LlmModelMap.catalog.dig("ollama", "llama-test", :api_id)).to eq("llama:test")
    end

    it "offers Delete alongside Hide in the list, not buried in the edit form" do
      as_super_user

      get admin_models_path
      list_body = response.body

      get edit_admin_model_path(LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5"))

      expect(list_body).to include("Delete")
      expect(response.body).not_to include("Delete")
    end

    it "deletes a model and removes it from the catalog" do
      as_super_user
      model = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5-mini")

      delete admin_model_path(model)

      expect(LlmModel.find_by(id: model.id)).to be_nil
      expect(LlmModelMap.catalog["openai"]).not_to have_key("gpt-5-mini")
    end

    describe "editing an existing model" do
      let(:model) { LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5") }

      it "saves a change and makes it visible without a restart" do
        as_super_user

        patch admin_model_path(model), params: { llm_model: {
          llm_id: model.llm_id, name: model.name, api_id: model.api_id,
          display_name: "GPT-5 (renamed)", active: "1",
          pricing_json: '{"input":1.25,"output":10.0}', defaults_json: "{}"
        } }

        expect(response).to redirect_to(admin_models_path)
        expect(LlmModelMap.catalog.dig("openai", "gpt-5", :display_name)).to eq("GPT-5 (renamed)")
      end

      it "parses the pricing and defaults JSON fields" do
        as_super_user

        patch admin_model_path(model), params: { llm_model: {
          llm_id: model.llm_id, name: model.name, api_id: model.api_id,
          display_name: model.display_name, active: "1",
          pricing_json: '{"input":2.0,"output":8.0,"verified":true}',
          defaults_json: '{"think":false}'
        } }

        expect(model.reload.pricing).to include("input" => 2.0, "verified" => true)
        expect(model.defaults).to eq("think" => false)
        expect(model.pricing_provenance).to eq(:verified)
      end

      it "leaves the record untouched when the JSON is malformed" do
        as_super_user
        before_pricing = model.pricing.dup

        patch admin_model_path(model), params: { llm_model: {
          llm_id: model.llm_id, name: model.name, api_id: model.api_id,
          display_name: model.display_name, active: "1",
          pricing_json: "{not json", defaults_json: "{}"
        } }

        expect(model.reload.pricing).to eq(before_pricing)
      end

      it "refuses an edit that would leave a chargeable model unpriced" do
        as_super_user

        patch admin_model_path(model), params: { llm_model: {
          llm_id: model.llm_id, name: model.name, api_id: model.api_id,
          display_name: model.display_name, active: "1",
          pricing_json: '{"input":0,"output":0}', defaults_json: "{}"
        } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(model.reload.pricing["input"]).not_to eq(0)
      end
    end

    describe "resetting from the checked-in YAML" do
      it "restores a value that was edited in the UI" do
        as_super_user
        model = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5")
        model.update!(display_name: "Edited In UI")

        post reseed_admin_models_path

        expect(response).to redirect_to(admin_models_path)
        expect(model.reload.display_name).to eq("GPT-5")
      end

      it "does not delete models added in the UI — reseed is not a purge" do
        as_super_user
        llm = Llm.find_by(family: "openai")
        added = llm.llm_models.create!(name: "ui-added", api_id: "ui.added", display_name: "UI Added",
                                       pricing: { "input" => 1.0, "output" => 2.0 })

        post reseed_admin_models_path

        expect(LlmModel.find_by(id: added.id)).to be_present
      end

      it "makes the restored catalog live immediately" do
        as_super_user
        model = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5")
        model.update!(active: false)
        LlmModelMap.reload!
        expect(LlmModelMap.catalog["openai"]).not_to have_key("gpt-5")

        post reseed_admin_models_path

        expect(LlmModelMap.catalog["openai"]).to have_key("gpt-5")
      end
    end

    describe "capability icons" do
      # The chat service's model grid uses bi-image / bi-eye / bi-tools with
      # these tooltips; the admin list should read the same way rather than
      # mixing emoji and bare text.
      it "renders image, vision and tools as icons with the chat service's labels" do
        as_super_user

        get admin_models_path

        expect(response.body).to include('title="Image generation"')
        expect(response.body).to include('title="Vision input"')
        expect(response.body).to include('title="Tool / function calling"')
      end

      it "uses no emoji or bare-text capability tags" do
        as_super_user

        get admin_models_path
        caps = response.body

        expect(caps).not_to include("🛠")
        expect(caps).not_to include("👁")
        expect(caps).not_to match(/>image<\/span>/)
      end

      it "greys out the tools icon for a Responses-only model instead of hiding it" do
        as_super_user

        get admin_models_path

        # gpt-5.5-pro supports tools but this server cannot route them.
        expect(response.body).to include("fa-screwdriver-wrench text-gray-300")
      end
    end

    describe "ordering" do
      # `position` carries the catalog's deliberate order, seeded from the
      # YAML. The column defaults to 0, so without appending, a model added
      # here ties with the first entry and surfaces second in its provider.
      it "appends a new model rather than landing it near the top" do
        as_super_user
        google = Llm.find_by(family: "google")
        highest = google.llm_models.maximum(:position)

        post admin_models_path, params: { llm_model: {
          llm_id: google.id, name: "gemini-zz-test", api_id: "gemini.zz.test",
          display_name: "Gemini ZZ", active: "1",
          pricing_json: '{"input":1.0,"output":2.0}', defaults_json: "{}"
        } }

        expect(LlmModel.find_by(name: "gemini-zz-test").position).to eq(highest + 1)
      end

      it "lists it last for its provider" do
        as_super_user
        google = Llm.find_by(family: "google")

        post admin_models_path, params: { llm_model: {
          llm_id: google.id, name: "gemini-zz-test", api_id: "gemini.zz.test",
          display_name: "Gemini ZZ", active: "1",
          pricing_json: '{"input":1.0,"output":2.0}', defaults_json: "{}"
        } }

        ordered = google.llm_models.reload.sort_by { |m| [ m.position, m.id ] }.map(&:name)
        expect(ordered.last).to eq("gemini-zz-test")
      end

      it "keeps the seeded order intact" do
        as_super_user
        google = Llm.find_by(family: "google")
        before = google.llm_models.sort_by { |m| [ m.position, m.id ] }.map(&:name)

        post admin_models_path, params: { llm_model: {
          llm_id: google.id, name: "gemini-zz-test", api_id: "gemini.zz.test",
          display_name: "Gemini ZZ", active: "1",
          pricing_json: '{"input":1.0,"output":2.0}', defaults_json: "{}"
        } }

        after = google.llm_models.reload.sort_by { |m| [ m.position, m.id ] }.map(&:name)
        expect(after.first(before.size)).to eq(before)
      end
    end

    it "hides a model from the catalog when deactivated" do
      as_super_user
      model = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5")

      patch toggle_active_admin_model_path(model)

      expect(LlmModelMap.catalog["openai"]).not_to have_key("gpt-5")
    end

    it "records a pricing review" do
      as_super_user
      model = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5")

      patch mark_reviewed_admin_model_path(model), params: { input: "1.30", output: "9.90" }

      expect(model.reload.pricing).to include("input" => 1.3, "output" => 9.9)
    end
  end

  describe "price provenance" do
    it "renders without touching the network before any check has run" do
      as_super_user
      get admin_models_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("prices never checked")
    end

    let(:pro) { LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5-5-pro") }

    before do
      Rails.cache.clear
      stub_request(:get, PricingReference::LITELLM_URL).to_return(status: 200, body: {
        "gpt-5.5-pro" => { "input_cost_per_token" => 30.0e-6, "output_cost_per_token" => 180.0e-6 }
      }.to_json)
      stub_request(:get, PricingReference::OPENROUTER_URL).to_return(status: 200, body: { "data" => [] }.to_json)
    end

    it "shows a model whose price disagrees with the public references" do
      as_super_user
      pro.update!(pricing: { "input" => 5.0, "output" => 40.0 })

      # The page renders from the last recorded check — it must never depend on
      # a third-party service being reachable at render time.
      post check_prices_admin_models_path
      get admin_models_path

      expect(response.body).to include("differ from the public references")
      expect(response.body).to include("30.0")
    end

    it "removes the row from the drift panel after applying, not just the price" do
      as_super_user
      pro.update!(pricing: { "input" => 5.0, "output" => 40.0 })
      post check_prices_admin_models_path

      patch apply_reference_price_admin_model_path(pro)
      get admin_models_path

      expect(response.body).not_to include("differ from the public references")
    end

    it "adopts a reference price and records where it came from" do
      as_super_user
      pro.update!(pricing: { "input" => 5.0, "output" => 40.0 })

      patch apply_reference_price_admin_model_path(pro)

      expect(pro.reload.pricing).to include("input" => 30.0, "output" => 180.0)
      expect(pro.pricing["source"]).to include("litellm")
      # An aggregator is evidence, not the provider's own word.
      expect(pro.pricing_provenance).to eq(:reference)
    end

    it "marks a price a human confirmed as verified" do
      as_super_user
      pro.update!(pricing: pro.pricing.merge("verified" => true))

      expect(pro.reload.pricing_provenance).to eq(:verified)
    end

    it "flags an extrapolated price as estimated from its notes" do
      # Built explicitly rather than read from the catalog: the real entries
      # were corrected to :reference on 2026-09-03, and a provenance rule
      # should not be asserted against whatever the catalog happens to hold.
      pro.update!(pricing: { "input" => 5.0, "output" => 40.0 },
                  notes: "PROVISIONAL pricing — extrapolated, never verified")

      expect(pro.reload.pricing_provenance).to eq(:estimated)
    end

    it "surfaces catalog models the provider no longer serves" do
      as_super_user
      ModelCatalogCheck.record!(provider: "openai", missing_from_provider: [ "gpt-5" ])

      get admin_models_path

      expect(response.body).to include("the provider no longer serves")
      expect(response.body).to include("gpt-5")
    end

    it "stops reporting a retired model once it has been hidden" do
      as_super_user
      ModelCatalogCheck.record!(provider: "openai", missing_from_provider: [ "gpt-5" ])
      model = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5")

      patch toggle_active_admin_model_path(model)
      get admin_models_path

      # Hidden models leave the catalog, so nagging about them is noise.
      expect(response.body).not_to include("the provider no longer serves")
    end

    it "does not mistake an alias for a retirement" do
      as_super_user
      # The catalog uses the alias; the API returns the dated snapshot.
      ModelCatalogCheck.record!(provider: "anthropic", missing_from_provider: [])

      get admin_models_path

      expect(response.body).not_to include("the provider no longer serves")
    end

    it "stops listing a discovered model as missing once it has been added" do
      as_super_user
      ModelCatalogCheck.record!(provider: "openai", new_in_provider: [
        { "api_id" => "gpt-9.9", "input" => 1.0, "output" => 2.0 }
      ])

      get admin_models_path
      expect(response.body).to include("gpt-9.9")

      post admin_models_path, params: { llm_model: {
        llm_id: Llm.find_by(family: "openai").id, name: "gpt-9-9", api_id: "gpt-9.9", display_name: "GPT 9.9",
        active: "1", pricing_json: '{"input":1.0,"output":2.0}', defaults_json: "{}"
      } }
      get admin_models_path

      # The recorded check is a snapshot; the panel must reflect the catalog.
      expect(response.body).not_to include("available but not in the catalog")
    end

    it "pre-fills a discovered model's price from the public references" do
      as_super_user

      get new_admin_model_path(provider: "openai", api_id: "gpt-5.5-pro")

      expect(response.body).to include("Price pre-filled")
      expect(response.body).to include("30.0")
      # An aggregator is evidence, not the provider's word.
      expect(response.body).to include("reference")
    end

    it "classes a per-image model as kind: image so the pre-filled form saves" do
      as_super_user
      stub_request(:get, PricingReference::LITELLM_URL).to_return(status: 200, body: {
        "gemini-3.1-flash-lite-image" => { "output_cost_per_image" => 0.0336 }
      }.to_json)
      Rails.cache.clear

      get new_admin_model_path(provider: "google", api_id: "gemini-3.1-flash-lite-image")

      # Pre-filling per_image pricing while leaving kind blank makes the form
      # unsaveable: validation would demand input/output instead.
      expect(response.body).to include("per_image")
      expect(response.body).to match(/<option selected[^>]*value="image"|value="image"[^>]*selected/)
    end

    it "saves an image model whose reference quotes per-image pricing" do
      as_super_user
      google = Llm.find_by(family: "google")

      post admin_models_path, params: { llm_model: {
        llm_id: google.id, name: "gemini-img-test", api_id: "gemini.img.test",
        display_name: "Gemini Img Test", kind: "image", active: "1",
        pricing_json: '{"per_image":0.0336}', defaults_json: "{}"
      } }

      expect(response).to redirect_to(admin_models_path)
      expect(LlmModelMap.catalog.dig("google", "gemini-img-test", :kind)).to eq(:image)
    end

    it "says so plainly when no reference price exists" do
      as_super_user

      get new_admin_model_path(provider: "openai", api_id: "gpt-nonexistent")

      expect(response.body).to include("No public reference price")
    end

    describe "updating all prices at once" do
      let(:flash_model) { LlmModel.joins(:llm).find_by(llms: { family: "google" }, name: "gemini-3-flash") }

      before do
        stub_request(:get, PricingReference::LITELLM_URL).to_return(status: 200, body: {
          "gpt-5.5-pro"     => { "input_cost_per_token" => 30.0e-6, "output_cost_per_token" => 180.0e-6 },
          "gemini-3-flash-preview" => { "input_cost_per_token" => 0.5e-6, "output_cost_per_token" => 3.0e-6 }
        }.to_json)
      end

      it "adopts the reference price for every model that differs" do
        as_super_user
        pro.update!(pricing: { "input" => 5.0, "output" => 40.0 })
        flash_model.update!(pricing: { "input" => 0.3, "output" => 2.5 })

        post apply_all_reference_prices_admin_models_path

        expect(pro.reload.pricing).to include("input" => 30.0, "output" => 180.0)
        expect(flash_model.reload.pricing).to include("input" => 0.5, "output" => 3.0)
      end

      it "leaves a human-verified price alone and says so" do
        as_super_user
        pro.update!(pricing: { "input" => 5.0, "output" => 40.0, "verified" => true })

        post apply_all_reference_prices_admin_models_path
        follow_redirect!

        # A bulk action driven by third-party aggregators must not quietly
        # override a price someone confirmed against the provider itself.
        expect(pro.reload.pricing["input"]).to eq(5.0)
        expect(response.body).to include("verified price")
      end

      it "clears the drift panel once applied" do
        as_super_user
        pro.update!(pricing: { "input" => 5.0, "output" => 40.0 })

        post apply_all_reference_prices_admin_models_path
        get admin_models_path

        expect(response.body).not_to include("differ from the public references")
      end
    end

    it "prefers a recorded source over the notes heuristic" do
      pro.update!(pricing: { "input" => 30.0, "output" => 180.0, "source" => "litellm+openrouter" },
                  notes: "PROVISIONAL pricing — stale note left behind")

      expect(pro.reload.pricing_provenance).to eq(:reference)
    end
  end

  describe "MCP administration" do
    it "flags a URL registered by more than one user" do
      as_super_user
      url = "https://dup.example.com/mcp"
      user.mcp_servers.create!(name: "mine", url: url)
      other.mcp_servers.create!(name: "theirs", url: url)

      get admin_mcp_servers_path

      expect(response.body).to include("duplicate")
    end

    it "lists servers belonging to other users, which the per-user screen cannot" do
      as_super_user
      other.mcp_servers.create!(name: "someone-elses", url: "https://other.example.com/mcp")

      get admin_mcp_servers_path

      expect(response.body).to include("someone-elses").and include(other.email)
    end
  end
end
