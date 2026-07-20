require "rails_helper"

RSpec.describe CatalogDiffer do
  describe ".diff" do
    it "labels a provider-only model as new_in_provider" do
      result = described_class.diff(
        provider_models: [
          { id: "gpt-5",   created_at: Date.new(2026, 5, 14) },
          { id: "gpt-6",   created_at: Date.new(2026, 7, 1) }
        ],
        catalog_api_ids: [ "gpt-5" ]
      )
      expect(result[:new_in_provider].map { |m| m[:id] }).to eq([ "gpt-6" ])
      expect(result[:missing_from_provider]).to be_empty
    end

    it "labels a catalog-only api_id as missing_from_provider" do
      result = described_class.diff(
        provider_models: [ { id: "gpt-5", created_at: nil } ],
        catalog_api_ids: [ "gpt-5", "gpt-4-deprecated" ]
      )
      expect(result[:missing_from_provider]).to eq([ "gpt-4-deprecated" ])
      expect(result[:new_in_provider]).to be_empty
    end

    it "returns empty arrays when everything matches" do
      result = described_class.diff(
        provider_models: [ { id: "x", created_at: nil }, { id: "y", created_at: nil } ],
        catalog_api_ids: [ "x", "y" ]
      )
      expect(result[:new_in_provider]).to be_empty
      expect(result[:missing_from_provider]).to be_empty
    end

    it "preserves created_at on new_in_provider entries" do
      created = Date.new(2026, 6, 1)
      result = described_class.diff(
        provider_models: [ { id: "novel", created_at: created } ],
        catalog_api_ids: []
      )
      expect(result[:new_in_provider].first[:created_at]).to eq(created)
    end

    it "handles empty inputs on both sides" do
      result = described_class.diff(provider_models: [], catalog_api_ids: [])
      expect(result).to eq(new_in_provider: [], missing_from_provider: [])
    end
  end
end
