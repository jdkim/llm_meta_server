require 'rails_helper'

RSpec.describe LlmApiKey, type: :model do
  let(:plain_api_key) { "plain_text_key_example" }
  let(:api_key_encrypter) { instance_double(ApiKeyEncrypter) }
  let(:ciphertext_blob) { "encrypted_api_key" }
  let(:base64_ciphertext) { "ダミー文字列" }
  let(:user) { User.create!(email: "test@example.com", google_id: 1) }
  let(:llm_api_key) { LlmApiKey.new(params) }

  before do
    allow(ApiKeyEncrypter).to receive(:new).and_return(api_key_encrypter)
    allow(api_key_encrypter).to receive(:encrypt).with(plain_api_key)
                                          .and_return(base64_ciphertext)
  end

  describe '#valid?' do
    subject { llm_api_key }

    context 'with valid required attributes' do
      let(:params) {
        {
          llm_type: "openai",
          api_key: plain_api_key,
          user: user
        }
      }
      it {
        is_expected.to be_valid
        expect(llm_api_key).to have_attributes(
                                 user: user,
                                 uuid: kind_of(String),
                                 llm_type: "openai",
                                 encrypted_api_key: base64_ciphertext
                               )
      }
    end

    context 'without required attributes' do
      let(:params) { {} }
      it 'shows errors for all required attributes', :aggregate_failures do
        is_expected.not_to be_valid
        expect(llm_api_key.errors[:llm_type]).to include("can't be blank")
      end
    end
  end
end
