require 'rails_helper'

RSpec.describe LlmModel, type: :model do
  let(:llm) { Llm.create!(name: "Test LLM", family: "test") }
  let(:llm_model) { LlmModel.new(params) }

  describe '#valid?' do
    subject { llm_model }

    context 'with valid name' do
      let(:params) { { name: "Test Model", llm: llm } }
      it { is_expected.to be_valid }
    end

    context 'without name' do
      let(:params) { { llm: llm } }
      it { is_expected.not_to be_valid }
    end

    context 'without llm' do
      let(:params) { { name: "Test Model" } }
      it { is_expected.not_to be_valid }
    end
  end

  describe 'belongs to llm' do
    subject { llm_model.llm }
    let(:params) { { name: "Test Model", llm: llm } }
    it {
      is_expected.to eq llm
    }
  end
end
