require 'rails_helper'

RSpec.describe LlmModel, type: :model do
  # family "ollama" is the free/local one, so these shape checks need no pricing.
  let(:llm) { Llm.find_or_create_by!(family: "ollama") { |l| l.name = "Ollama" } }
  let(:llm_model) { LlmModel.new(params) }

  describe '#valid?' do
    subject { llm_model }

    context 'with valid name' do
      # A catalog entry now needs api_id and display_name too, and `name` is
      # the meta_id, which appears in routes — so it must be URL-safe.
      let(:params) { { name: "test-model", display_name: "Test Model", api_id: "test-model", llm: llm } }
      it { is_expected.to be_valid }
    end

    context 'with a name that is not URL-safe' do
      let(:params) { { name: "gpt-3.5-turbo", display_name: "X", api_id: "gpt-3.5-turbo", llm: llm } }
      it { is_expected.not_to be_valid }
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

  describe ".catalog_order" do
    # Chat models before image generators, then most expensive first — the
    # order the YAML was hand-maintained in, now derived so it stays true as
    # models are added rather than depending on someone slotting each row in.
    let(:google) { Llm.find_or_create_by!(family: "google") { |l| l.name = "Google" } }

    def build(name, pricing, kind: nil)
      google.llm_models.create!(name: name, api_id: name, display_name: name.titleize,
                                kind: kind, pricing: pricing)
    end

    it "puts chat models before image generators" do
      img  = build("img-a", { "per_image" => 9.99 }, kind: "image")
      chat = build("chat-a", { "input" => 0.01, "output" => 0.02 })

      expect(described_class.catalog_order([ img, chat ])).to eq([ chat, img ])
    end

    it "ranks chat models most expensive first" do
      cheap = build("cheap-a", { "input" => 0.5, "output" => 1.0 })
      dear  = build("dear-a",  { "input" => 9.0, "output" => 20.0 })

      expect(described_class.catalog_order([ cheap, dear ]).map(&:name)).to eq(%w[dear-a cheap-a])
    end

    it "ranks image generators by their per-image price" do
      cheap = build("img-cheap", { "per_image" => 0.03 }, kind: "image")
      dear  = build("img-dear",  { "per_image" => 0.13 }, kind: "image")

      expect(described_class.catalog_order([ cheap, dear ]).map(&:name)).to eq(%w[img-dear img-cheap])
    end

    it "sorts free local models to the end of their group, not the top" do
      ollama = Llm.find_by(family: "ollama")
      free   = ollama.llm_models.create!(name: "free-a", api_id: "free:a", display_name: "Free A")
      paid   = build("paid-a", { "input" => 1.0, "output" => 2.0 })

      expect(described_class.catalog_order([ free, paid ]).map(&:name)).to eq(%w[paid-a free-a])
    end

    it "breaks ties on display name so the order is stable" do
      b = build("tie-b", { "input" => 1.0, "output" => 2.0 })
      a = build("tie-a", { "input" => 1.0, "output" => 2.0 })

      expect(described_class.catalog_order([ b, a ]).map(&:name)).to eq(%w[tie-a tie-b])
    end
  end
end
