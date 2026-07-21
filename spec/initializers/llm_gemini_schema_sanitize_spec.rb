require "rails_helper"

# Guards config/initializers/llm_gemini_schema_sanitize.rb — the patch that
# routes LLM::Function's serialized parameters through GeminiSchemaNormalizer
# when the target provider is Gemini. Without this, MCP tool schemas using
# type-arrays, uniqueItems, or additionalProperties 400 Gemini's API.
RSpec.describe "LLM::Function Gemini schema-sanitize patch" do
  let(:function) do
    LLM::Function.new("test_tool") do |fn|
      fn.description "does a thing"
      # instance_variable_set matches how McpToolAdapter injects the schema.
      fn.instance_variable_set(:@params, {
        type: "object",
        additionalProperties: false,
        properties: {
          limit: { type: [ "integer", "null" ] },
          tags:  { type: "array", items: { type: "string" }, uniqueItems: true }
        }
      })
    end
  end

  let(:gemini)    { double("LLM::Gemini").tap    { |d| allow(d.class).to receive(:to_s).and_return("LLM::Gemini") } }
  let(:anthropic) { double("LLM::Anthropic").tap { |d| allow(d.class).to receive(:to_s).and_return("LLM::Anthropic") } }
  let(:openai)    { double("LLM::OpenAI").tap    { |d| allow(d.class).to receive(:to_s).and_return("LLM::OpenAI") } }

  it "sanitizes parameters when adapting for Gemini" do
    result = function.adapt(gemini)

    params = result[:parameters]
    # Gemini-forbidden fields must be gone
    expect(params).not_to have_key(:additionalProperties)
    expect(params[:properties][:tags]).not_to have_key(:uniqueItems)
    # Type-array must be rewritten
    expect(params[:properties][:limit]).to eq(type: "integer", nullable: true)
  end

  it "leaves Anthropic's shape untouched (parameters not normalized)" do
    result = function.adapt(anthropic)
    # Anthropic uses `input_schema:` key, not `parameters:`, and accepts the
    # full JSON Schema — the patch must not touch it.
    expect(result[:input_schema][:additionalProperties]).to eq(false)
    expect(result[:input_schema][:properties][:limit][:type]).to eq([ "integer", "null" ])
    expect(result[:input_schema][:properties][:tags][:uniqueItems]).to eq(true)
  end

  it "leaves OpenAI's shape untouched (parameters not normalized)" do
    result = function.adapt(openai)
    # OpenAI accepts type-arrays, uniqueItems, and additionalProperties.
    params = result[:function][:parameters]
    expect(params[:additionalProperties]).to eq(false)
    expect(params[:properties][:limit][:type]).to eq([ "integer", "null" ])
    expect(params[:properties][:tags][:uniqueItems]).to eq(true)
  end
end
