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
    it 'returns encrypted_api_key when key exists' do
      user = User.create!(email: "test@example.com", google_id: 1)
      llm_api_key = user.llm_api_keys.create!(uuid: "uuid123", llm_type: "openai", encrypted_api_key: "encrypted_value")
      expect(user.key_for('uuid123').encrypted_api_key).to eq("encrypted_value")
    end

    it 'returns nil when key does not exist' do
      user = User.create!(email: "test@example.com", google_id: 1)
      expect(user.key_for('not_found')).to be_nil
    end
  end
end
