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

    context "with generation params" do
      it "passes generation_params to LlmRbFacade" do
        allow(LlmRbFacade).to receive(:call!).and_return("Hi!")

        post :create, params: {
          llm_api_key_uuid: uuid,
          model_name: model_name,
          prompt: "Hello",
          temperature: 0.7,
          max_tokens: 1024
        }

        expect(response).to have_http_status(:success)
        expect(LlmRbFacade).to have_received(:call!)
          .with(model_id, "Hello", generation_params: hash_including(:temperature, :max_tokens))
      end
    end

    context "with unsupported params" do
      it "filters out unsupported params" do
        allow(LlmRbFacade).to receive(:call!).and_return("Hi!")

        post :create, params: {
          llm_api_key_uuid: uuid,
          model_name: model_name,
          prompt: "Hello",
          temperature: 0.5,
          unsupported_param: "bad"
        }

        expect(response).to have_http_status(:success)
        expect(LlmRbFacade).to have_received(:call!) do |_model_id, _prompt, generation_params:|
          expect(generation_params.keys).to contain_exactly(:temperature)
        end
      end
    end
  end
end
