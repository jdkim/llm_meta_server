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
end
