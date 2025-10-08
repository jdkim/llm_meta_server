require 'rails_helper'

RSpec.describe User, type: :model do
  let(:user) { User.new(params) }
  describe '#valid?' do
    subject { user }

    context 'with valid email, google_id' do
      let(:params) { { email: "test@example.com", google_id: 1 } }
      it { is_expected.to be_valid }
    end

    context 'without email' do
      let(:params) { { google_id: 1 } }
      it {
        is_expected.not_to be_valid
        expect(user.errors[:email]).to include("can't be blank")
      }
    end

    context 'without google_id' do
      let(:params) { { email: "test@example.com" } }
      it {
        is_expected.not_to be_valid
        expect(user.errors[:google_id]).to include("can't be blank")
      }
    end

    context 'with duplicate email' do
      before { User.create!(email: "test@example.com", google_id: 1) }
      let(:user) { User.new(email: "test@example.com", google_id: 2) }
      it 'is not valid' do
        expect(user).not_to be_valid
        expect(user.errors[:email]).to include("has already been taken")
      end
    end

    context 'with duplicate google_id' do
      before { User.create!(email: "test1@example.com", google_id: 1) }
      let(:user) { User.new(email: "test2@example.com", google_id: 1) }
      it 'is not valid' do
        expect(user).not_to be_valid
        expect(user.errors[:google_id]).to include("has already been taken")
      end
    end
  end

  describe '#retrieve_key' do
    let(:params) { { email: "test@example.com", google_id: 1 } }
    let(:llm_api_key) { double("LlmApiKey", uuid: "uuid123", encrypted_api_key: "encrypted_value") }
    let(:decrypted_value) { "decrypted_api_key" }

    before do
      allow(user.llm_api_keys).to receive(:find_by).with(uuid: 'uuid123').and_return(llm_api_key)
      encryptable_api_key_instance = double('EncryptableApiKey')
      allow(EncryptableApiKey).to receive(:new).with(encrypted_api_key: 'encrypted_value').and_return(encryptable_api_key_instance)
      allow(encryptable_api_key_instance).to receive(:plain_api_key).and_return(decrypted_value)
      allow(llm_api_key).to receive(:encryptable_api_key).and_return(encryptable_api_key_instance)
    end

    it 'returns decrypted api key when key exists' do
      expect(user.key_for('uuid123').plain_api_key).to eq(decrypted_value)
    end

    it 'returns nil when key does not exist' do
      allow(user.llm_api_keys).to receive(:find_by).with(uuid: 'not_found').and_return(nil)
      expect(user.key_for('not_found')).to be_nil
    end
  end
end
