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

  describe '#as_json' do
    # /api/llms feeds the chat app's provider cards, including the "locked"
    # ones shown to visitors with no API key. Those listed models in raw row
    # order while the picker used catalog order, so the same provider read
    # differently depending on whether you were signed in.
    it 'lists models in catalog order — chat models first, priciest first' do
      names   = Llm.find_by(family: "google").as_json[:models].map { |m| m[:name] }
      catalog = LlmModel.catalog_order(
        LlmModel.joins(:llm).where(llms: { family: "google" }).select(&:active?)
      ).map(&:name)

      expect(names).to eq(catalog)
    end

    it 'puts image generators after chat models' do
      kinds = Llm.find_by(family: "google").as_json[:models].map { |m| m[:kind].to_s == "image" }

      expect(kinds).to eq(kinds.sort_by { |image| image ? 1 : 0 })
    end

    it 'omits hidden models — a teaser must not advertise what is switched off' do
      LlmModel.joins(:llm).find_by(llms: { family: "google" }, name: "gemini-3-5-flash").update!(active: false)

      names = Llm.find_by(family: "google").as_json[:models].map { |m| m[:name] }

      expect(names).not_to include("gemini-3-5-flash")
    end
  end
end
