require "rails_helper"

# config/initializers/openai_responses_history.rb patches llm.rb's Responses
# request adapter, which labels every string content `input_text` regardless
# of role. OpenAI rejects that for assistant items — they need `output_text` —
# which is why multi-turn requests could not use the Responses API at all.
RSpec.describe "OpenAI Responses history labelling" do
  def adapt(role, content)
    LLM::OpenAI::RequestAdapter::Respond.new(LLM::Message.new(role, content)).adapt
  end

  it "labels assistant text output_text" do
    expect(adapt("assistant", "hi there"))
      .to eq({ role: "assistant", content: [ { type: :output_text, text: "hi there" } ] })
  end

  it "leaves user text as input_text" do
    expect(adapt("user", "hello"))
      .to eq({ role: "user", content: [ { type: :input_text, text: "hello" } ] })
  end

  it "leaves system text as input_text" do
    expect(adapt("system", "be terse"))
      .to eq({ role: "system", content: [ { type: :input_text, text: "be terse" } ] })
  end

  it "reads the role from plain hashes too, not just LLM::Message" do
    adapted = LLM::OpenAI::RequestAdapter::Respond.new({ role: "assistant", content: "hi" }).adapt

    expect(adapted).to eq({ role: "assistant", content: [ { type: :output_text, text: "hi" } ] })
  end

  it "adapts a whole conversation the way the Responses API expects it" do
    messages = [ LLM::Message.new("user", "q1"),
                 LLM::Message.new("assistant", "a1"),
                 LLM::Message.new("user", "q2") ]

    adapted = Class.new { include LLM::OpenAI::RequestAdapter }.new.adapt(messages, mode: :response)

    expect(adapted.map { |m| m[:content].first[:type] }).to eq(%i[input_text output_text input_text])
  end

  # Non-string content (images, files, function output) must keep taking the
  # original code path — the patch only concerns plain text.
  it "does not disturb non-string content" do
    expect { adapt("assistant", 42) }.to raise_error(LLM::PromptError)
  end
end
