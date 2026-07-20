require "rails_helper"

RSpec.describe ModelCatalogValidator do
  # Build a fake catalog and stub LlmModelMap::MODEL_MAP for each example.
  # This keeps the tests independent of whatever's shipped in llm_models.yml.
  def stub_catalog(map)
    stub_const("LlmModelMap::MODEL_MAP", map)
  end

  let(:today) { Date.new(2026, 7, 20) }

  describe ".validate" do
    context "with a well-formed catalog" do
      before do
        stub_catalog(
          "openai" => {
            "gpt-x" => {
              api_id: "gpt-x", display_name: "GPT-X",
              pricing: { input: 1.0, output: 5.0, reviewed_at: today }
            }
          },
          "ollama" => {
            "local-x" => { api_id: "local-x:latest", display_name: "Local X" }
          },
          "google" => {
            "gemini-image" => {
              api_id: "gemini-image", display_name: "Gemini Image", kind: "image"
            }
          }
        )
      end

      it "returns no errors and no warnings" do
        result = described_class.validate(today: today)
        expect(result[:errors]).to be_empty
        expect(result[:warnings]).to be_empty
      end
    end

    describe "required-field errors" do
      it "flags missing api_id" do
        stub_catalog("openai" => { "no-api" => { display_name: "No API",
                                                 pricing: { input: 1.0, output: 5.0, reviewed_at: today } } })
        expect(described_class.validate(today: today)[:errors]).to include(/openai\/no-api: missing api_id/)
      end

      it "flags missing display_name" do
        stub_catalog("openai" => { "no-name" => { api_id: "no-name",
                                                  pricing: { input: 1.0, output: 5.0, reviewed_at: today } } })
        expect(described_class.validate(today: today)[:errors]).to include(/openai\/no-name: missing display_name/)
      end
    end

    describe "endpoint + kind whitelisting" do
      it "flags an unknown endpoint value" do
        stub_catalog("openai" => { "weird" => { api_id: "weird", display_name: "W",
                                                endpoint: "grpc",
                                                pricing: { input: 1.0, output: 5.0, reviewed_at: today } } })
        expect(described_class.validate(today: today)[:errors]).to include(/endpoint=.*grpc/)
      end

      it "accepts a valid endpoint" do
        stub_catalog("openai" => { "ok" => { api_id: "ok", display_name: "OK",
                                             endpoint: "responses",
                                             pricing: { input: 1.0, output: 5.0, reviewed_at: today } } })
        expect(described_class.validate(today: today)[:errors]).to be_empty
      end

      it "flags an unknown kind value" do
        stub_catalog("openai" => { "vid" => { api_id: "vid", display_name: "V",
                                              kind: "video",
                                              pricing: { input: 1.0, output: 5.0, reviewed_at: today } } })
        expect(described_class.validate(today: today)[:errors]).to include(/kind=.*video/)
      end
    end

    describe "pricing enforcement" do
      it "requires pricing on chargeable models" do
        stub_catalog("openai" => { "no-price" => { api_id: "no-price", display_name: "NP" } })
        expect(described_class.validate(today: today)[:errors]).to include(/missing pricing block/)
      end

      it "requires pricing.input and pricing.output to be numeric" do
        stub_catalog("openai" => { "half-price" => { api_id: "h", display_name: "H",
                                                     pricing: { input: 1.0, reviewed_at: today } } })
        errs = described_class.validate(today: today)[:errors]
        expect(errs).to include(/pricing\.output missing/)
      end

      it "does not require pricing for ollama models" do
        stub_catalog("ollama" => { "local" => { api_id: "local:latest", display_name: "Local" } })
        expect(described_class.validate(today: today)[:errors]).to be_empty
      end

      it "does not require pricing for kind: image models" do
        stub_catalog("google" => { "img" => { api_id: "img", display_name: "Img", kind: "image" } })
        expect(described_class.validate(today: today)[:errors]).to be_empty
      end

      it "warns if a non-chargeable model has a pricing block (would be ignored)" do
        stub_catalog("ollama" => { "local" => { api_id: "l", display_name: "L",
                                                pricing: { input: 1.0, output: 5.0, reviewed_at: today } } })
        result = described_class.validate(today: today)
        expect(result[:errors]).to be_empty
        expect(result[:warnings]).to include(/has pricing block but is not chargeable/)
      end
    end

    describe "reviewed_at freshness" do
      it "warns when reviewed_at is missing" do
        stub_catalog("openai" => { "no-date" => { api_id: "nd", display_name: "ND",
                                                  pricing: { input: 1.0, output: 5.0 } } })
        result = described_class.validate(today: today)
        expect(result[:errors]).to be_empty
        expect(result[:warnings]).to include(/reviewed_at missing/)
      end

      it "warns when reviewed_at is older than the stale threshold" do
        stale = today - (described_class::STALE_AFTER_DAYS + 1)
        stub_catalog("openai" => { "old" => { api_id: "old", display_name: "Old",
                                              pricing: { input: 1.0, output: 5.0, reviewed_at: stale } } })
        result = described_class.validate(today: today)
        expect(result[:errors]).to be_empty
        expect(result[:warnings].join).to match(/reviewed_at is \d+ days old/)
      end

      it "does not warn when reviewed_at is within the stale window" do
        fresh = today - (described_class::STALE_AFTER_DAYS - 1)
        stub_catalog("openai" => { "fresh" => { api_id: "f", display_name: "F",
                                                pricing: { input: 1.0, output: 5.0, reviewed_at: fresh } } })
        expect(described_class.validate(today: today)[:warnings]).to be_empty
      end

      it "accepts reviewed_at as a string date and parses it" do
        stub_catalog("openai" => { "str" => { api_id: "s", display_name: "S",
                                              pricing: { input: 1.0, output: 5.0, reviewed_at: today.iso8601 } } })
        expect(described_class.validate(today: today)[:warnings]).to be_empty
      end

      it "flags an unparseable reviewed_at as an error" do
        stub_catalog("openai" => { "junk" => { api_id: "j", display_name: "J",
                                               pricing: { input: 1.0, output: 5.0, reviewed_at: "not a date" } } })
        result = described_class.validate(today: today)
        expect(result[:warnings]).to include(/not a valid date/)
      end
    end
  end
end
