require "rails_helper"

RSpec.describe ModelCatalogScaffold do
  describe ".meta_id_for" do
    it "flattens dots and colons, matching the catalog's existing meta_ids" do
      expect(described_class.meta_id_for("gpt-5.5-pro")).to eq("gpt-5-5-pro")
      expect(described_class.meta_id_for("qwen3.6:35b-fast")).to eq("qwen3-6-35b-fast")
    end

    it "produces a URL-safe id (meta_id appears in routes and favorites)" do
      expect(described_class.meta_id_for("gemini-3.1-pro")).to match(/\A[a-zA-Z0-9\-_]+\z/)
    end
  end

  describe ".entry_for" do
    subject(:yaml) { described_class.entry_for("gpt-5.6", provider: "openai", today: Date.new(2026, 9, 2)) }

    it "emits a block that parses as YAML under its provider key" do
      parsed = YAML.safe_load("openai:\n" + yaml, permitted_classes: [ Date ])
      entry  = parsed.dig("openai", "gpt-5-6")

      expect(entry["api_id"]).to eq("gpt-5.6")
      expect(entry["supports_tools"]).to be(true)
      expect(entry.dig("pricing", "reviewed_at").to_s).to eq("2026-09-02")
    end

    it "points at the provider's pricing page, the one step that cannot be automated" do
      expect(yaml).to include("https://openai.com/api/pricing")
    end

    it "honours vision/tools overrides" do
      entry = described_class.entry_for("x", provider: "google", vision: false, tools: false)
      expect(entry).to include("supports_vision: false").and include("supports_tools: false")
    end
  end

  describe ".display_name_with_provider" do
    # Google publishes marketing names ("Nano Banana 2 Lite") that carry no
    # model identity, and the hand-written catalog entries kept both parts.
    # Deriving from the api_id alone silently dropped the provider's name and
    # made new entries inconsistent with the existing ones.
    it "keeps both when the provider name adds something" do
      expect(described_class.display_name_with_provider("gemini-3.1-flash-lite-image", "Nano Banana 2 Lite"))
        .to eq("Gemini 3.1 Flash Lite Image (Nano Banana 2 Lite)")
    end

    it "matches the convention already in the catalog" do
      expect(described_class.display_name_with_provider("gemini-3-pro-image", "Nano Banana Pro"))
        .to eq("Gemini 3 Pro Image (Nano Banana Pro)")
    end

    it "does not duplicate a provider name that already matches" do
      expect(described_class.display_name_with_provider("claude-opus-5", "Claude Opus 5")).to eq("Claude Opus 5")
    end

    it "falls back to the derived name when the provider publishes none" do
      # OpenAI's list-models has no display name field.
      expect(described_class.display_name_with_provider("gpt-5.6-terra", nil)).to eq("GPT 5.6 Terra")
    end

    it "ignores a blank provider name" do
      expect(described_class.display_name_with_provider("gpt-5.6-terra", "  ")).to eq("GPT 5.6 Terra")
    end
  end
end
