require 'rails_helper'

RSpec.describe Llm, type: :model do
  let(:llm) { Llm.new(params) }
  describe '#valid?' do
    subject { llm }

    context 'with valid name' do
      let(:params) { { name: "Test LLM", family: "test" } }
      it { is_expected.to be_valid }
    end

    context 'without name' do
      let(:params) { { family: "test" } }
      it {
        is_expected.not_to be_valid
        expect(llm.errors[:name]).to include("can't be blank")
      }
    end

    context 'with duplicate name' do
      before { Llm.create!(name: "Test LLM", family: "test") }
      let(:params) { { name: "Test LLM", family: "test2" } }
      it {
        is_expected.not_to be_valid
        expect(llm.errors[:name]).to include("has already been taken")
      }
    end
  end
end
