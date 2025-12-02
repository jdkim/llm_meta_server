require 'rails_helper'

RSpec.describe LlmApiKey, type: :model do
  let(:plain_api_key) { "plain_text_key_example" }
  let(:base64_ciphertext) { "dummy_base64_encoded_encrypted_api_key" }
  let(:user) { User.create!(email: "test@example.com", google_id: 1) }
  let(:llm_api_key) { LlmApiKey.new(params) }
  let(:encryptable_api_key_A) { instance_double(EncryptableApiKey, encrypted_api_key: base64_ciphertext) }

  before do
    allow(EncryptableApiKey).to receive(:new).with(plain_api_key: plain_api_key)
                                             .and_return(encryptable_api_key_A)
  end

  describe '#valid?' do
    subject { llm_api_key }

    context 'with valid required attributes' do
      let(:params) {
        {
          llm_type: "openai",
          encryptable_api_key: encryptable_api_key_A,
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

    context 'when updating with encryptable_api_key, encrypted_api_key is updated' do
      let(:params) {
        {
          llm_type: "openai",
          encryptable_api_key: encryptable_api_key_A,
          user: user
        }
      }

      let(:new_plain_api_key) { "new_plain_text_key_example" }
      let(:new_base64_ciphertext) { "new_dummy_base64_encoded_encrypted_api_key" }
      let(:new_encryptable_api_key) { instance_double(EncryptableApiKey, encrypted_api_key: new_base64_ciphertext) }

      before do
        allow(EncryptableApiKey).to receive(:new).with(plain_api_key: new_plain_api_key)
                                              .and_return(new_encryptable_api_key)
        llm_api_key.save!
        llm_api_key.update!(encryptable_api_key: new_encryptable_api_key)
      end

      it {
        is_expected.to have_attributes(
                         user: user,
                         uuid: kind_of(String),
                         llm_type: "openai",
                         encrypted_api_key: new_base64_ciphertext
                       )
      }
    end

    context 'when updating with nil encryptable_api_key, raises an error' do
      let(:params) {
        {
          llm_type: "openai",
          encryptable_api_key: encryptable_api_key_A,
          user: user
        }
      }

      before do
        llm_api_key.save!
      end

      it 'raises an ArgumentError' do
        expect {
          llm_api_key.encryptable_api_key = nil
        }.to raise_error(ArgumentError, "encryptable_api_key cannot be nil")
      end
    end
  end

  describe '#encryptable_api_key' do
    subject { llm_api_key.encryptable_api_key }

    let(:params) {
      {
        llm_type: "openai",
        encryptable_api_key: encryptable_api_key_A,
        user: user
      }
    }

    let(:encryptable_api_key_B) { instance_double(EncryptableApiKey) }

    before do
      llm_api_key.save! # Save first to trigger encryption
      # Clear the memoized @encryptable_api_key to allow re-instantiation
      llm_api_key.instance_variable_set(:@encryptable_api_key, nil)
      allow(EncryptableApiKey).to receive(:new).with(encrypted_api_key: base64_ciphertext)
                                        .and_return(encryptable_api_key_B)
    end

    it {
      is_expected.to eq(encryptable_api_key_B)
    }
  end

  describe '#as_json' do
    subject { llm_api_key.as_json }

    let(:params) {
      {
        llm_type: "openai",
        description: "Test API Key",
        encryptable_api_key: encryptable_api_key_A,
        user: user
      }
    }

    before do
      llm_api_key.save!
    end

    it 'returns uuid, llm_type, description, and available_models' do
      expect(subject.keys).to match_array(%w[uuid llm_type description available_models])
    end

    it 'does not include encrypted_api_key' do
      expect(subject).not_to have_key('encrypted_api_key')
    end

    it 'does not include user information' do
      expect(subject).not_to have_key('user')
      expect(subject).not_to have_key('user_id')
    end

    it 'includes the correct values', :aggregate_failures do
      expect(subject['uuid']).to eq(llm_api_key.uuid)
      expect(subject['llm_type']).to eq("openai")
      expect(subject['description']).to eq("[OpenAI] Test API Key")
    end

    context 'when description is nil' do
      let(:params) {
        {
          llm_type: "anthropic",
          description: nil,
          encryptable_api_key: encryptable_api_key_A,
          user: user
        }
      }

      it 'includes nil description' do
        expect(subject['description']).to eq("[Anthropic] ")
      end
    end
  end
end
