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

  # A tool result stops being the trailing "current input" as soon as the turn
  # progresses past it, and then it is seeded as history instead. llm.rb builds
  # a tool result from an LLM::Function::Return held as the message content;
  # seeded as a plain string the id is absent and the provider rejects the
  # whole request with "Invalid 'messages': missing field `tool_call_id`".
  describe "a tool result in the middle of history" do
    def tool_message(messages, llm)
      described_class.send(:messages_to_llm_objects, messages, llm: llm)
                     .find { |m| m.role.to_s == "tool" }
    end

    it "carries the tool_call_id the provider matches against" do
      content = tool_message(history, openai).content

      expect(content).to be_a(LLM::Function::Return)
      expect(content.id).to eq("call_1")
    end

    it "keeps the result the browser reported" do
      expect(tool_message(history, openai).content.value).to eq('{"ok":true}')
    end

    it "does this for every provider, not just the OpenAI family" do
      expect(tool_message(history, anthropic).content).to be_a(LLM::Function::Return)
    end

    it "leaves an id-less result as a plain string rather than inventing an id" do
      expect(tool_message(history(id: nil), openai).content).to be_a(String)
    end
  end

  # The two defects behind tonight's failures were both mismatches between the
  # shape we build and the shape llm.rb sends. Asserting our own shape cannot
  # catch that, so these drive the real adapter and check the request body.
  describe "what llm.rb actually puts on the wire" do
    def adapt(message)
      LLM::OpenAI::RequestAdapter::Completion.new(message).adapt
    end

    def seeded(messages)
      described_class.send(:messages_to_llm_objects, messages, llm: openai)
    end

    it "sends the assistant turn WITH its tool_calls, not as an empty turn" do
      body = adapt(seeded(history).find { |m| m.role.to_s == "assistant" })

      expect(body[:tool_calls]).to be_present
      expect(body[:tool_calls].first["id"]).to eq("call_1")
      expect(body[:tool_calls].first["function"]["name"]).to eq("set_dictionaries")
    end

    it "sends the tool result with the tool_call_id the provider matches on" do
      body = adapt(seeded(history).find { |m| m.role.to_s == "tool" })

      expect(body[:role]).to eq("tool")
      expect(body[:tool_call_id]).to eq("call_1")
    end
  end

  describe "a turn that emitted several tool calls at once" do
    let(:parallel) do
      [
        { "role" => "user", "content" => "do both" },
        { "role" => "assistant", "content" => "",
          "tool_calls" => [
            { "id" => "call_a", "name" => "set_dictionaries", "arguments" => { "names" => [ "mondo" ] } },
            { "id" => "call_b", "name" => "set_text",         "arguments" => { "text" => "hi" } }
          ] },
        { "role" => "tool", "tool_call_id" => "call_a", "name" => "set_dictionaries", "content" => '{"ok":true}' },
        { "role" => "tool", "tool_call_id" => "call_b", "name" => "set_text",         "content" => '{"ok":true}' }
      ]
    end

    it "keeps every call, not just the first" do
      native = described_class.send(:messages_to_llm_objects, parallel, llm: openai)
                              .find { |m| m.role.to_s == "assistant" }
                              .extra[:original_tool_calls]

      expect(native.map { |c| c["id"] }).to eq(%w[call_a call_b])
    end

    it "keeps each result paired with its own call" do
      tools = described_class.send(:messages_to_llm_objects, parallel, llm: openai)
                             .select { |m| m.role.to_s == "tool" }

      expect(tools.map { |m| m.content.id }).to eq(%w[call_a call_b])
    end
  end

  # The shape that actually failed: two completed rounds behind the current
  # input, so BOTH tool results are history rather than trailing input.
  describe "history with more than one completed tool round" do
    let(:two_rounds) do
      [
        { "role" => "user", "content" => "annotate this" },
        { "role" => "assistant", "content" => "",
          "tool_calls" => [ { "id" => "call_1", "name" => "set_dictionaries", "arguments" => { "names" => [ "mondo" ] } } ] },
        { "role" => "tool", "tool_call_id" => "call_1", "name" => "set_dictionaries", "content" => '{"ok":true}' },
        { "role" => "assistant", "content" => "",
          "tool_calls" => [ { "id" => "call_2", "name" => "set_text", "arguments" => { "text" => "hi" } } ] },
        { "role" => "tool", "tool_call_id" => "call_2", "name" => "set_text", "content" => '{"ok":true}' }
      ]
    end

    it "gives every assistant turn its calls and every result its id" do
      seeded = described_class.send(:messages_to_llm_objects, two_rounds, llm: openai)

      assistants = seeded.select { |m| m.role.to_s == "assistant" }
      tools      = seeded.select { |m| m.role.to_s == "tool" }

      expect(assistants.map { |m| m.extra[:original_tool_calls].first["id"] }).to eq(%w[call_1 call_2])
      expect(tools.map { |m| m.content.id }).to eq(%w[call_1 call_2])
    end

    it "renders both rounds into a body the provider would accept" do
      bodies = described_class.send(:messages_to_llm_objects, two_rounds, llm: openai)
                              .map { |m| LLM::OpenAI::RequestAdapter::Completion.new(m).adapt }

      tool_bodies = bodies.select { |b| b[:role].to_s == "tool" }
      expect(tool_bodies.map { |b| b[:tool_call_id] }).to eq(%w[call_1 call_2])
      expect(tool_bodies.none? { |b| b[:tool_call_id].nil? }).to be(true)
    end
  end
end
