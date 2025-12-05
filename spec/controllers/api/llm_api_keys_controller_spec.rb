require 'rails_helper'

RSpec.describe Api::LlmApiKeysController, type: :controller do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }

  before do
    allow(controller).to receive(:authenticate_user!).and_return(true)
    allow(controller).to receive(:current_user).and_return(user)
  end

  describe 'GET #index' do
    context 'when user has no API keys' do
      it 'returns empty array' do
        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response['llm_api_keys']).to eq([])
      end
    end

    context 'when user has API keys' do
      before do
        encryptable_key = instance_double(EncryptableApiKey, encrypted_api_key: "encrypted_key")
        allow(EncryptableApiKey).to receive(:new).and_return(encryptable_key)

        LlmApiKey.create!(
          user: user,
          llm_type: "openai",
          description: "OpenAI Key",
          encryptable_api_key: encryptable_key
        )

        LlmApiKey.create!(
          user: user,
          llm_type: "anthropic",
          description: "Anthropic Key",
          encryptable_api_key: encryptable_key
        )
      end

      it 'returns only user registered API keys without Ollama' do
        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response['llm_api_keys'].length).to eq(2)

        llm_types = json_response['llm_api_keys'].map { |key| key['llm_type'] }
        expect(llm_types).to contain_exactly('openai', 'anthropic')
        expect(llm_types).not_to include('ollama')
      end

      it 'includes model information for each API key' do
        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        json_response['llm_api_keys'].each do |key|
          expect(key).to have_key('uuid')
          expect(key).to have_key('llm_type')
          expect(key).to have_key('description')
          expect(key).to have_key('available_models')
        end
      end
    end
  end
end
