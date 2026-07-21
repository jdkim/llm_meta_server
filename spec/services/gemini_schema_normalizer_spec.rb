require "rails_helper"

RSpec.describe GeminiSchemaNormalizer do
  describe ".normalize" do
    it "leaves a simple schema unchanged" do
      schema = { type: "string" }
      expect(described_class.normalize(schema)).to eq(schema)
    end

    it "returns non-hash input untouched" do
      expect(described_class.normalize(nil)).to be_nil
      expect(described_class.normalize("abc")).to eq("abc")
      expect(described_class.normalize([ 1, 2 ])).to eq([ 1, 2 ])
    end

    it "deep-symbolizes keys so downstream serialization sees a consistent shape" do
      schema = { "type" => "object", "properties" => { "name" => { "type" => "string" } } }
      result = described_class.normalize(schema)
      expect(result[:type]).to eq("object")
      expect(result[:properties][:name][:type]).to eq("string")
    end

    describe "type-array rewriting (Gemini's #1 rejection cause)" do
      it "converts [string, null] to type + nullable" do
        result = described_class.normalize(type: [ "string", "null" ])
        expect(result).to eq(type: "string", nullable: true)
      end

      it "is order-insensitive: [null, string] also becomes type + nullable" do
        result = described_class.normalize(type: [ "null", "string" ])
        expect(result).to eq(type: "string", nullable: true)
      end

      it "leaves single-string type untouched" do
        expect(described_class.normalize(type: "integer")).to eq(type: "integer")
      end

      it "on a true union type (no null), picks the first non-null" do
        # Gemini has no union type — losing alternatives is intentional and
        # documented in the normalizer. Better to send a valid partial schema
        # than to 400 the whole request.
        result = described_class.normalize(type: [ "string", "number" ])
        expect(result).to eq(type: "string")
      end

      it "returns an empty hash when the type array has nothing declarable" do
        expect(described_class.normalize(type: [ "null" ])).to eq({})
        expect(described_class.normalize(type: [])).to eq({})
      end
    end

    describe "field stripping (Gemini's #2 and #3 rejection causes)" do
      it "removes uniqueItems" do
        result = described_class.normalize(type: "array", items: { type: "string" }, uniqueItems: true)
        expect(result).not_to have_key(:uniqueItems)
        expect(result[:type]).to eq("array")
      end

      it "removes additionalProperties" do
        result = described_class.normalize(type: "object", properties: {}, additionalProperties: false)
        expect(result).not_to have_key(:additionalProperties)
        expect(result[:type]).to eq("object")
      end
    end

    describe "recursion into nested schema subtrees" do
      it "recurses into object properties" do
        result = described_class.normalize(
          type: "object",
          properties: {
            name: { type: [ "string", "null" ] },
            age:  { type: "integer" }
          }
        )
        expect(result[:properties][:name]).to eq(type: "string", nullable: true)
        expect(result[:properties][:age]).to eq(type: "integer")
      end

      it "recurses into array items" do
        result = described_class.normalize(
          type: "array",
          items: { type: [ "string", "null" ], uniqueItems: true }
        )
        # uniqueItems inside items is also stripped
        expect(result[:items]).to eq(type: "string", nullable: true)
      end

      it "recurses into oneOf / anyOf / allOf branches" do
        result = described_class.normalize(
          oneOf: [
            { type: [ "string", "null" ] },
            { type: "object", additionalProperties: false }
          ]
        )
        expect(result[:oneOf][0]).to eq(type: "string", nullable: true)
        expect(result[:oneOf][1]).to eq(type: "object")
      end

      it "handles the real-world MCP shape (nested + stripped + rewritten)" do
        # Modeled on tool schemas we've actually seen come back from Smithery
        # brokers — the exact combination that produced today's failing chat.
        schema = {
          type: "object",
          additionalProperties: false,
          properties: {
            q:          { type: "string" },
            limit:      { type: [ "integer", "null" ] },
            categories: { type: "array", items: { type: "string" }, uniqueItems: true }
          }
        }
        result = described_class.normalize(schema)

        expect(result).not_to have_key(:additionalProperties)
        expect(result[:properties][:q]).to eq(type: "string")
        expect(result[:properties][:limit]).to eq(type: "integer", nullable: true)
        expect(result[:properties][:categories]).to eq(type: "array", items: { type: "string" })
      end
    end

    it "does not mutate the input schema" do
      input = { type: [ "string", "null" ], properties: { name: { type: "string" } }, additionalProperties: false }
      snapshot = Marshal.dump(input)
      described_class.normalize(input)
      expect(Marshal.dump(input)).to eq(snapshot)
    end
  end
end
