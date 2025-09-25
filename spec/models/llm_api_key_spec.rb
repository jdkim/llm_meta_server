require 'rails_helper'

RSpec.describe LlmApiKey, type: :model do
  let(:user) { User.create!(email: "test@example.com", google_id: 1) }
  let(:llm_api_key) { LlmApiKey.new(params) }

  describe '#valid?' do
    subject { llm_api_key }

    context 'with valid required attributes' do
      let(:params) {
        {
          uuid: SecureRandom.uuid,
          llm_type: "openai",
          encrypted_api_key: "encrypted_key_example",
          user: user
        }
      }
      it {
        is_expected.to be_valid
        expect(llm_api_key.user).to eq(user)
        expect(llm_api_key.uuid).not_to be_nil
        expect(llm_api_key.llm_type).to eq("openai")
        expect(llm_api_key.encrypted_api_key).to eq("encrypted_key_example")
      }
    end

    context 'without required attributes' do
      let(:params) { {} }
      it {
        is_expected.not_to be_valid
        expect(llm_api_key.errors[:uuid]).to include("can't be blank")
        expect(llm_api_key.errors[:llm_type]).to include("can't be blank")
        expect(llm_api_key.errors[:encrypted_api_key]).to include("can't be blank")
      }
    end

    context 'with duplicate attributes' do
      before { LlmApiKey.create!(params) }
      let(:params) {
        {
          uuid: SecureRandom.uuid,
          llm_type: "openai",
          encrypted_api_key: "encrypted_key_example",
          user: user
        }
      }
      it {
        is_expected.not_to be_valid
        expect(llm_api_key.errors[:uuid]).to include("has already been taken")
      }
    end
  end
end