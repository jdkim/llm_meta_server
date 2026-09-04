require "rails_helper"

# Providers publish no pricing API, so the catalog's prices were typed in — and
# three were extrapolated, under-charging by 3-6x (gpt-5.5-pro at 5/40 against
# an actual 30/180) with nothing to catch it. These references make that
# detectable.
RSpec.describe PricingReference do
  let(:litellm_body) do
    {
      "gpt-5.5-pro" => { "input_cost_per_token" => 30.0e-6,  "output_cost_per_token" => 180.0e-6 },
      "gpt-5"       => { "input_cost_per_token" => 1.25e-6,  "output_cost_per_token" => 10.0e-6 },
      "embedding-x" => { "input_cost_per_token" => 1.0e-6 } # no output cost — skipped
    }.to_json
  end

  let(:openrouter_body) do
    { "data" => [
      { "id" => "openai/gpt-5.5-pro", "pricing" => { "prompt" => "0.00003", "completion" => "0.00018" } },
      { "id" => "openai/gpt-5",       "pricing" => { "prompt" => "0.00000125", "completion" => "0.00001" } }
    ] }.to_json
  end

  before do
    Rails.cache.clear
    stub_request(:get, described_class::LITELLM_URL).to_return(status: 200, body: litellm_body)
    stub_request(:get, described_class::OPENROUTER_URL).to_return(status: 200, body: openrouter_body)
  end

  describe ".table" do
    it "converts per-token costs to USD per 1M tokens" do
      expect(described_class.for("gpt-5").input).to eq(1.25)
      expect(described_class.for("gpt-5").output).to eq(10.0)
    end

    it "marks a quote as agreed when both sources match" do
      quote = described_class.for("gpt-5.5-pro")

      expect(quote.sources).to contain_exactly("litellm", "openrouter")
      expect(quote.agree).to be(true)
    end

    it "skips entries without both an input and an output cost" do
      expect(described_class.for("embedding-x")).to be_nil
    end

    it "raises FetchError rather than half-building a table when a source is down" do
      stub_request(:get, described_class::LITELLM_URL).to_return(status: 500, body: "")
      Rails.cache.clear

      expect { described_class.raw_table(refresh: true) }.to raise_error(described_class::FetchError)
    end
  end

  describe ".compare" do
    it "flags a catalog price that disagrees with the reference" do
      model = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5-5-pro")
      model.update!(pricing: { "input" => 5.0, "output" => 40.0 })
      LlmModelMap.reload!

      row = described_class.compare(refresh: true).find { |r| r[:meta_id] == "gpt-5-5-pro" }

      expect(row[:ours_input]).to eq(5.0)
      expect(row[:ref_input]).to eq(30.0)
      expect(row[:agree]).to be(true)
    end

    it "stays quiet when the catalog matches" do
      model = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-5")
      model.update!(pricing: { "input" => 1.25, "output" => 10.0 })

      rows = described_class.compare(refresh: true)
      expect(rows.map { |r| r[:meta_id] }).not_to include("gpt-5")
    end

    it "ignores local models, which are free and have no reference" do
      rows = described_class.compare(refresh: true)
      expect(rows.map { |r| r[:llm_type] }).not_to include("ollama")
    end
  end

  describe "cache shape" do
    # These write to the shared cache directly; clear afterwards so a poisoned
    # entry cannot leak into another spec file and fail depending on order.
    after { Rails.cache.clear }

    # A Quote struct marshalled into the cache breaks with "struct size
    # differs" the moment a member is added — which took down /admin/models
    # after per_image and released_on were introduced. Cache plain data.
    it "stores plain hashes, not Struct instances" do
      row = described_class.raw_table(refresh: true).values.first

      expect(row).to be_a(Hash)
      expect(row).not_to be_a(described_class::Quote)
    end

    it "survives a cached entry written before a member was added" do
      Rails.cache.write(described_class::CACHE_KEY,
                        { "gpt-5" => { "input" => 1.25, "output" => 10.0, "sources" => [ "litellm" ] } })

      quote = described_class.for("gpt-5")

      expect(quote.input).to eq(1.25)
      expect(quote.per_image).to be_nil
      expect(quote.released_on).to be_nil
    end
  end

  describe "provenance" do
    it "records the source and marks the price unverified — an aggregator is not the provider" do
      pricing = described_class.for("gpt-5").to_pricing(today: Date.new(2026, 9, 3))

      expect(pricing["source"]).to include("litellm")
      expect(pricing["verified"]).to be(false)
      expect(pricing["reviewed_at"]).to eq("2026-09-03")
    end
  end

  describe "image models" do
    # Image generators bill per generated image, not per token, so they carry
    # per_image instead of input/output — and the catalog stores it that way.
    let(:litellm_body) do
      { "gemini-3-pro-image" => { "output_cost_per_image" => 0.134,
                                  "input_cost_per_token" => 2.0e-6, "output_cost_per_token" => 12.0e-6 } }.to_json
    end
    let(:openrouter_body) { { "data" => [] }.to_json }

    it "prefers the per-image cost over the per-token one" do
      quote = described_class.for("gemini-3-pro-image", refresh: true)

      expect(quote).to be_image
      expect(quote.per_image).to eq(0.134)
    end

    it "writes pricing as per_image, not input/output" do
      pricing = described_class.for("gemini-3-pro-image", refresh: true).to_pricing

      expect(pricing).to include("per_image" => 0.134)
      expect(pricing).not_to have_key("input")
    end

    it "flags an image model whose per-image price drifted" do
      model = LlmModel.joins(:llm).find_by(llms: { family: "google" }, name: "gemini-3-pro-image")
      model.update!(pricing: { "per_image" => 0.10 })
      LlmModelMap.reload!

      row = described_class.compare(refresh: true).find { |r| r[:meta_id] == "gemini-3-pro-image" }

      expect(row[:per_image]).to be(true)
      expect(row[:ref_input]).to eq(0.134)
    end

    it "does not compare an image model against a per-token reference" do
      model = LlmModel.joins(:llm).find_by(llms: { family: "openai" }, name: "gpt-image-1")
      model.update!(pricing: { "per_image" => 0.04 })
      LlmModelMap.reload!

      # gpt-image-1 is billed per image *token* upstream, so no per-image
      # reference exists; comparing it to a token price would be meaningless.
      expect(described_class.compare(refresh: true).map { |r| r[:meta_id] }).not_to include("gpt-image-1")
    end
  end

  describe "release dates" do
    # Providers expose this unevenly — OpenAI returns `created`, Anthropic
    # `created_at`, Google nothing at all — so OpenRouter's timestamp is what
    # covers the catalog broadly.
    let(:litellm_body) { {}.to_json }
    let(:openrouter_body) do
      { "data" => [
        { "id" => "google/gemini-3.1-pro-preview", "created" => 1_771_459_200,
          "pricing" => { "prompt" => "0.000002", "completion" => "0.000012" } }
      ] }.to_json
    end

    it "reads the release date from OpenRouter" do
      expect(described_class.for("gemini-3.1-pro-preview", refresh: true).released_on).to eq(Date.new(2026, 2, 19))
    end

    it "backfills only models that have no date" do
      model = LlmModel.joins(:llm).find_by(llms: { family: "google" }, name: "gemini-3-1-pro")
      model.update!(released_on: nil)
      described_class.raw_table(refresh: true)

      expect { described_class.backfill_release_dates! }
        .to change { model.reload.released_on }.from(nil).to(Date.new(2026, 2, 19))
    end

    it "never overwrites a date entered by hand" do
      model = LlmModel.joins(:llm).find_by(llms: { family: "google" }, name: "gemini-3-1-pro")
      model.update!(released_on: Date.new(2020, 1, 1))
      described_class.raw_table(refresh: true)

      described_class.backfill_release_dates!

      expect(model.reload.released_on).to eq(Date.new(2020, 1, 1))
    end
  end
end
