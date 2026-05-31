require 'rails_helper'

RSpec.describe Api::ChatsController, type: :controller do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }
  let(:model_name) { "llama3.2" }
  let(:model_id) { "llama3.2" }
  let(:uuid) { "ollama-local" }

  before do
    allow(controller).to receive(:authenticate_user!).and_return(true)
    allow(controller).to receive(:current_user).and_return(user)
    allow(controller).to receive(:bearer_token).and_return(nil)
    allow(LlmModelMap).to receive(:fetch!).with(model_name).and_return(model_id)
  end

  describe "POST #create" do
    context "without generation params" do
      it "calls LlmRbFacade without generation_params" do
        allow(LlmRbFacade).to receive(:call!)
          .with(model_id, "Hello", generation_params: {})
          .and_return("Hi!")

        post :create, params: { llm_api_key_uuid: uuid, model_name: model_name, prompt: "Hello" }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json["response"]["message"]).to eq("Hi!")
      end
    end

    context "with generation_settings (nested pass-through)" do
      it "forwards every key/value verbatim — numbers, booleans, nested hashes" do
        allow(LlmRbFacade).to receive(:call!).and_return("Hi!")

        post :create, params: {
          llm_api_key_uuid: uuid,
          model_name: model_name,
          prompt: "Hello",
          generation_settings: {
            temperature: 0.7,
            max_tokens: 1024,
            think: true,
            options: { num_ctx: 8192 }
          }
        }

        expect(response).to have_http_status(:success)
        expect(LlmRbFacade).to have_received(:call!) do |_model_id, _prompt, generation_params:, **|
          # Note: Rails params come through as strings unless the request is
          # JSON; in form-encoded posts numbers/booleans serialize as strings.
          expect(generation_params.keys).to contain_exactly(:temperature, :max_tokens, :think, :options)
          expect(generation_params[:options]).to include(:num_ctx)
        end
      end

      it "passes an empty hash when no generation_settings are provided" do
        allow(LlmRbFacade).to receive(:call!).and_return("Hi!")

        post :create, params: {
          llm_api_key_uuid: uuid, model_name: model_name, prompt: "Hello"
        }

        expect(LlmRbFacade).to have_received(:call!)
          .with(model_id, "Hello", generation_params: {})
      end
    end
  end
end
