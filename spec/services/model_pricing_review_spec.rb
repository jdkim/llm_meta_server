require "rails_helper"

RSpec.describe ModelPricingReview do
  def catalog_model(meta_id)
    LlmModel.joins(:llm).find_by(llms: { family: "anthropic" }, name: meta_id)
  end

  describe ".due" do
    it "is empty while every price was reviewed inside the threshold" do
      expect(described_class.due(today: Date.new(2026, 9, 2))).to eq([])
    end

    it "lists chargeable models once their review has gone stale, with a pricing page" do
      rows = described_class.due(today: Date.new(2099, 1, 1))

      expect(rows).to be_present
      expect(rows.map { |r| r[:llm_type] }).not_to include("ollama") # local models are free
      expect(rows.first[:pricing_url]).to be_present
      expect(rows.first[:reason]).to match(/reviewed \d+ days ago/)
    end

    it "flags a model whose pricing has no reviewed_at at all" do
      model = catalog_model("claude-sonnet-5")
      model.update!(pricing: model.pricing.except("reviewed_at"))
      LlmModelMap.reload!

      row = described_class.due(today: Date.new(2026, 9, 2)).find { |r| r[:meta_id] == "claude-sonnet-5" }
      expect(row[:reason]).to eq("no reviewed_at")
    end
  end

  describe ".mark_reviewed!" do
    it "stamps reviewed_at and reports what changed" do
      changed = described_class.mark_reviewed!(meta_id: "claude-sonnet-5", provider: "anthropic",
                                               today: Date.new(2026, 9, 2))

      expect(changed).to eq([ "reviewed_at" ])
      expect(catalog_model("claude-sonnet-5").pricing["reviewed_at"]).to eq("2026-09-02")
    end

    it "updates prices when given, leaving other models untouched" do
      before_other = catalog_model("claude-opus-4-8").pricing.dup

      described_class.mark_reviewed!(meta_id: "claude-sonnet-5", provider: "anthropic",
                                     input: "2.5", output: "11", today: Date.new(2026, 9, 2))

      expect(catalog_model("claude-sonnet-5").pricing).to include("input" => 2.5, "output" => 11.0)
      expect(catalog_model("claude-opus-4-8").pricing).to eq(before_other)
    end

    it "makes the change visible through LlmModelMap without a restart" do
      described_class.mark_reviewed!(meta_id: "claude-sonnet-5", provider: "anthropic", input: "7.77")

      expect(LlmModelMap.catalog.dig("anthropic", "claude-sonnet-5", :pricing)[:input]).to eq(7.77)
    end

    it "raises NotFound for an unknown model" do
      expect {
        described_class.mark_reviewed!(meta_id: "nope", provider: "anthropic")
      }.to raise_error(described_class::NotFound)
    end
  end
end
