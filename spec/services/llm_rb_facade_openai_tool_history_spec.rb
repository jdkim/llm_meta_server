require "rails_helper"

# Replaying a client-orchestrated tool round-trip to an OpenAI-shaped provider.
#
# llm.rb's OpenAI request adapter re-sends a PRIOR tool call from
# extra[:original_tool_calls] — not from extra[:tool_calls], which is llm.rb's
# own normalised copy and is never sent anywhere. Message#tool_call? reads the
# normalised key, so without the native one the adapter still took the
# tool-call branch and emitted `content: nil, tool_calls: nil`: an empty
# assistant turn.
#
# The symptom was two layers away. gpt-oss on Bedrock, seeing a tool result it
# had no record of requesting, re-issued the same call every round until the
# budget ran out; PubDictionaries' annotate flow never reached its second step.
# qwen on Ollama tolerated the same history, because only the OpenAI family
# reads this key.
RSpec.describe LlmRbFacade, "replaying tool history to an OpenAI-shaped provider" do
  let(:openai)    { LLM::OpenAI.new(key: "sk-test") }
  let(:anthropic) { LLM::Anthropic.new(key: "sk-test") }
  let(:bedrock)   { BedrockClient.new(key: "sk-test") }

  def history(id: "call_1", arguments: { "names" => %w[mondo uberon] })
    [
      { "role" => "user", "content" => "annotate this" },
      { "role" => "assistant", "content" => "",
        "tool_calls" => [ { "id" => id, "name" => "set_dictionaries", "arguments" => arguments } ] },
      { "role" => "tool", "tool_call_id" => id, "name" => "set_dictionaries", "content" => '{"ok":true}' }
    ]
  end

  def assistant_message(messages, llm)
    described_class.send(:messages_to_llm_objects, messages, llm: llm)
                   .find { |m| m.role.to_s == "assistant" }
  end

  it "keeps the assistant turn that only carries tool_calls" do
    msg = assistant_message(history, openai)

    expect(msg).to be_present
    expect(msg.tool_call?).to be(true)
  end

  it "gives the OpenAI adapter the native shape it actually sends" do
    native = assistant_message(history, openai).extra[:original_tool_calls]

    expect(native).to eq([
      { "id" => "call_1", "type" => "function",
        "function" => { "name" => "set_dictionaries",
                        "arguments" => '{"names":["mondo","uberon"]}' } }
    ])
  end

  # The failure this guards: an assistant turn sent as `tool_calls: nil`, which
  # the model reads as "I never called it" and so calls again.
  it "would not send an empty tool-call turn" do
    msg = assistant_message(history, openai)

    expect(msg.extra[:original_tool_calls]).to be_present
  end

  it "serialises arguments as a JSON string, not an object" do
    native = assistant_message(history, openai).extra[:original_tool_calls]

    expect(native.first.dig("function", "arguments")).to be_a(String)
  end

  it "covers Bedrock, which reaches the same adapter by subclassing OpenAI" do
    expect(BedrockClient.ancestors).to include(LLM::OpenAI)
    expect(assistant_message(history, bedrock).extra[:original_tool_calls]).to be_present
  end

  # Anthropic and Gemini expect their own shapes under the same key, so
  # handing them OpenAI's would be worse than leaving it unset.
  it "adds nothing for a provider whose adapter expects a different shape" do
    expect(assistant_message(history, anthropic).extra[:original_tool_calls]).to be_nil
    expect(assistant_message(history, anthropic).extra[:tool_calls]).to be_present
  end

  it "adds nothing when no provider is known" do
    expect(assistant_message(history, nil).extra[:original_tool_calls]).to be_nil
  end

  # A pair the provider cannot match is rejected outright, so an id-less call
  # keeps the old behaviour rather than inventing one that matches nothing.
  it "skips a tool call that carries no id" do
    msg = assistant_message(history(id: nil), openai)

    expect(msg.extra[:original_tool_calls]).to be_nil
    expect(msg.extra[:tool_calls]).to be_present
  end

  it "passes through arguments that are already a JSON string" do
    native = assistant_message(history(arguments: '{"names":["x"]}'), openai)
             .extra[:original_tool_calls]

    expect(native.first.dig("function", "arguments")).to eq('{"names":["x"]}')
  end
end
