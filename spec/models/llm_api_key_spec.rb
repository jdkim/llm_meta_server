require 'rails_helper'

RSpec.describe LlmApiKey, type: :model do
  let(:plain_api_key) { "plain_text_key_example" }
  let(:api_key_encrypter) { instance_double(ApiKeyEncrypter) }
  let(:base64_ciphertext) { "dummy_base64_encoded_encrypted_api_key" }
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

  describe '#update' do
    subject { llm_api_key }

    context 'when updating with api_key, encrypted_api_key is updated and api_key is not retained' do
      let(:params) {
        {
          llm_type: "openai",
          api_key: plain_api_key,
          user: user
        }
      }

      let(:new_plain_api_key) { "new_plain_text_key_example" }
      let(:new_base64_ciphertext) { "new_dummy_base64_encoded_encrypted_api_key" }

      before do
        allow(api_key_encrypter).to receive(:encrypt).with(new_plain_api_key)
                                              .and_return(new_base64_ciphertext)
        llm_api_key.update!(api_key: new_plain_api_key)
      end

      it {
        is_expected.to have_attributes(
                         user: user,
                         uuid: kind_of(String),
                         llm_type: "openai",
                         encrypted_api_key: new_base64_ciphertext
                       )
        expect(llm_api_key.api_key).to be_nil
      }
    end

    context 'when updating empty api_key, encrypted_api_key remains unchanged' do
      let(:params) {
        {
          llm_type: "openai",
          api_key: plain_api_key,
          user: user
        }
      }

      let(:new_plain_api_key) { "" }

      before do
        llm_api_key.save! # Save first
        llm_api_key.update!(api_key: new_plain_api_key)
      end

      it {
        is_expected.to have_attributes(
                         user: user,
                         uuid: kind_of(String),
                         llm_type: "openai",
                         encrypted_api_key: base64_ciphertext
                       )
        expect(llm_api_key.api_key).to be_nil
      }
    end
  end

  describe '#encryptable_api_key' do
    subject { llm_api_key.encryptable_api_key }

    let(:params) {
      {
        llm_type: "openai",
        api_key: plain_api_key,
        user: user
      }
    }

    let(:encryptable_api_key_instance) { instance_double(EncryptableApiKey) }

    before do
      llm_api_key.save! # Save first to trigger encryption
      allow(EncryptableApiKey).to receive(:new).with(encrypted_api_key: base64_ciphertext)
                                        .and_return(encryptable_api_key_instance)
    end

    it {
      is_expected.to eq(encryptable_api_key_instance)
    }
  end
end
