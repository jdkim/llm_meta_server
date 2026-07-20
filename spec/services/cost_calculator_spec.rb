require "rails_helper"

RSpec.describe CostCalculator do
  describe ".compute" do
    it "computes input+output cost for a known model" do
      # claude-sonnet-4-6: input 3.00/MTok, output 15.00/MTok
      # 10_000 input → 0.03 USD = 3 cents
      # 2_000 output → 0.03 USD = 3 cents
      cents = described_class.compute(
        llm_type: "anthropic", meta_id: "claude-sonnet-4-6",
        input_tokens: 10_000, output_tokens: 2_000
      )
      expect(cents).to eq(6)
    end

    it "returns 0 for ollama models (local)" do
      cents = described_class.compute(
        llm_type: "ollama", meta_id: "qwen3-6-35b",
        input_tokens: 100_000, output_tokens: 50_000
      )
      expect(cents).to eq(0)
    end

    it "returns 0 and logs a warning for unknown model" do
      expect(Rails.logger).to receive(:warn).with(/no pricing for openai\/bogus-model/)
      cents = described_class.compute(
        llm_type: "openai", meta_id: "bogus-model",
        input_tokens: 1_000, output_tokens: 500
      )
      expect(cents).to eq(0)
    end

    it "returns 0 for zero tokens" do
      cents = described_class.compute(
        llm_type: "anthropic", meta_id: "claude-opus-4-7",
        input_tokens: 0, output_tokens: 0
      )
      expect(cents).to eq(0)
    end

    it "rounds fractional cents to nearest integer" do
      # gpt-5-mini: output 2.00/MTok. 251 output tokens → 0.000502 USD = 0.0502 cents → rounds to 0
      # 2510 output tokens → 0.00502 USD = 0.502 cents → rounds to 1
      expect(
        described_class.compute(llm_type: "openai", meta_id: "gpt-5-mini",
                                input_tokens: 0, output_tokens: 251)
      ).to eq(0)
      expect(
        described_class.compute(llm_type: "openai", meta_id: "gpt-5-mini",
                                input_tokens: 0, output_tokens: 2510)
      ).to eq(1)
    end

    it "computes a high-cost Opus call correctly" do
      # claude-opus-4-7: input 5.00/MTok, output 25.00/MTok (as of 2026-07-21)
      # 50_000 input → 0.25 USD = 25 cents
      # 10_000 output → 0.25 USD = 25 cents
      cents = described_class.compute(
        llm_type: "anthropic", meta_id: "claude-opus-4-7",
        input_tokens: 50_000, output_tokens: 10_000
      )
      expect(cents).to eq(50)
    end
  end
end
