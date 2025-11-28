require 'rails_helper'

RSpec.describe Api::LlmApiKeysController, type: :controller do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }

  before do
    allow(controller).to receive(:authenticate_user!).and_return(true)
    allow(controller).to receive(:current_user).and_return(user)
  end

  describe 'GET #index' do
    context 'when user has no Ollama key' do
      before do
        # Create a non-Ollama key
        encryptable_key = instance_double(EncryptableApiKey, encrypted_api_key: "encrypted_key")
        allow(EncryptableApiKey).to receive(:new).and_return(encryptable_key)

        LlmApiKey.create!(
          user: user,
          llm_type: "openai",
          description: "OpenAI Key",
          encryptable_api_key: encryptable_key
        )
      end

      it 'automatically includes default Ollama key' do
        allow(LlmModelMap).to receive(:available_models_for).and_return([])

        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response['llm_api_keys'].length).to eq(2)

        ollama_key = json_response['llm_api_keys'].find { |key| key['llm_type'] == 'ollama' }
        expect(ollama_key).not_to be_nil
        expect(ollama_key['description']).to include('Local Ollama')
      end
    end

    context 'when user has only non-Ollama keys' do
      before do
        encryptable_key = instance_double(EncryptableApiKey, encrypted_api_key: "encrypted_key")
        allow(EncryptableApiKey).to receive(:new).and_return(encryptable_key)

        LlmApiKey.create!(
          user: user,
          llm_type: "anthropic",
          description: "Anthropic Key",
          encryptable_api_key: encryptable_key
        )
      end

      it 'always includes default Ollama key' do
        allow(LlmModelMap).to receive(:available_models_for).and_return([])

        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response['llm_api_keys'].length).to eq(2)

        ollama_key = json_response['llm_api_keys'].find { |key| key['llm_type'] == 'ollama' }
        expect(ollama_key).not_to be_nil
        expect(ollama_key['description']).to include('Local Ollama')
        expect(ollama_key['uuid']).to eq('ollama-local')
      end
    end
  end
end
