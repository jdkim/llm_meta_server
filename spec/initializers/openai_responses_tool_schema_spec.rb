require "rails_helper"

# config/initializers/openai_responses_tool_schema.rb drops llm.rb's
# `strict: true` / `additionalProperties: false` from function tools sent to
# /v1/responses. OpenAI's strict mode demands that every key in `properties`
# also appear in `required`, which most MCP schemas violate by having optional
# parameters at all.
RSpec.describe "OpenAI Responses function-tool schema" do
  # PubDictionaries' find_ids: one required parameter, one optional. Strict
  # mode rejects this shape outright.
  let(:schema) {
    {
      type: "object",
      properties: {
        labels: { type: "string", description: "comma-separated terms" },
        dictionary: { type: "string", description: "optional dictionary name" }
      },
      required: [ "labels" ]
    }
  }

  let(:function) {
    LLM::Function.new("find_ids") do |fn|
      fn.description "look up ids"
      fn.instance_variable_set(:@params, schema)
    end
  }

  let(:responses) { LLM::OpenAI::Responses.new(double("provider")) }
  let(:completions) { LLM::OpenAI.new(key: "sk-test") }

  it "sends the schema without strict mode" do
    adapted = function.adapt(responses)

    expect(adapted).to eq({ type: "function", name: "find_ids",
                            description: "look up ids", parameters: schema })
  end

  it "does not smuggle additionalProperties into the schema" do
    function.adapt(responses)

    expect(schema).not_to have_key(:additionalProperties)
  end

  it "leaves the chat-completions shape alone" do
    adapted = function.adapt(completions)

    expect(adapted).to eq({ type: "function", name: "find_ids",
                            function: { name: "find_ids", description: "look up ids",
                                        parameters: schema } })
  end
end
