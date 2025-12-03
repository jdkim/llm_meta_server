require 'rails_helper'

RSpec.describe Api::LlmsController, type: :controller do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }

  before do
    allow(controller).to receive(:authenticate_user!).and_return(true)
    allow(controller).to receive(:current_user).and_return(user)
  end

  describe 'GET #index' do
    context 'when there are no registered LLM services' do
      it 'returns only Ollama service' do
        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response['llms'].length).to eq(1)

        ollama = json_response['llms'].first
        expect(ollama['llm_type']).to eq('ollama')
        expect(ollama['description']).to include('Local Ollama')
        expect(ollama['uuid']).to eq('ollama-local')
        expect(ollama['available_models']).to be_an(Array)
      end
    end

    context 'when there are registered LLM services' do
      before do
        # Create LLM services with models
        openai = Llm.create!(name: 'OpenAI')
        openai.llm_models.create!(name: 'gpt-4', display_name: 'GPT-4', api_id: 'gpt-4')
        openai.llm_models.create!(name: 'gpt-3.5-turbo', display_name: 'GPT-3.5 Turbo', api_id: 'gpt-3.5-turbo')

        anthropic = Llm.create!(name: 'Anthropic')
        anthropic.llm_models.create!(name: 'claude-3', display_name: 'Claude 3 Opus', api_id: 'claude-3-opus-20240229')
      end

      it 'returns all LLM services including Ollama' do
        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response['llms'].length).to eq(3)

        llm_names = json_response['llms'].map { |llm| llm['name'] || llm['llm_type'] }
        expect(llm_names).to include('OpenAI', 'Anthropic', 'ollama')
      end

      it 'includes model information for each service' do
        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        openai = json_response['llms'].find { |llm| llm['name'] == 'OpenAI' }
        expect(openai['models'].length).to eq(2)
        expect(openai['models'].map { |m| m['name'] }).to include('gpt-4', 'gpt-3.5-turbo')
      end

      it 'includes Ollama with available models' do
        get :index

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        ollama = json_response['llms'].find { |llm| llm['llm_type'] == 'ollama' }
        expect(ollama).not_to be_nil
        expect(ollama['available_models']).to be_an(Array)
        expect(ollama['uuid']).to eq('ollama-local')
      end
    end
  end
end
