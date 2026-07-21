require "rails_helper"

# Guards config/initializers/llm_anthropic_tool_role.rb — the patch that makes
# LLM::Anthropic#tool_role return :user (Anthropic's protocol) instead of
# llm.rb's default :tool. Without this, multi-turn tool loops on Anthropic
# 400 on iteration 2 with "Unexpected role \"tool\"".
RSpec.describe "LLM::Anthropic tool_role initializer" do
  it "returns :user (matches Anthropic's tool-result-as-user-message protocol)" do
    llm = LLM.anthropic(key: "dummy-key-for-instantiation")
    expect(llm.tool_role).to eq(:user)
  end

  it "does not affect other providers' tool_role (defense against over-reach)" do
    # Sanity check that the patch is scoped to Anthropic. OpenAI keeps the
    # base :tool default, which is correct for OpenAI's protocol.
    llm = LLM.openai(key: "dummy-key-for-instantiation")
    expect(llm.tool_role).to eq(:tool)
  end

  # Integration: verifies llm.rb's LLM::Bot#talk actually consumes the patched
  # tool_role when appending tool-result messages to session history. Guards
  # against upstream changes that would silently make our patch a no-op —
  # e.g. Bot#talk hardcoding :tool, or refactoring away from provider.tool_role.
  #
  # This is what the actual failing dev chat hit: iteration 1's appended
  # tool-result message rode along in iteration 2's messages: with role="tool"
  # and Anthropic 400'd. If this test fails, the same bug will resurface.
  it "makes LLM::Session append tool-result messages with :user role (integration)" do
    llm = LLM.anthropic(key: "dummy-key-for-instantiation")
    session = LLM::Session.new(llm, model: "claude-opus-4-8")

    # Mock the actual API call — we're not testing Anthropic's endpoint, we're
    # testing that Bot#talk uses our patched tool_role for the history append.
    # Plain double (not instance_double) because LLM::Response's `choices`
    # lives on a subtype, not the base class — matches the mocking pattern
    # used elsewhere in the suite.
    fake_response = double("Response",
      choices: [ double("Choice", content: "ok") ],
      body: nil,
      functions: [])
    allow(llm).to receive(:complete).and_return(fake_response)

    tool_result = LLM::Function::Return.new(id: "call-1", name: "test_tool", value: { ok: true })
    session.chat([ tool_result ])

    # Find the message that carries the tool_result payload — its role must
    # be :user for Anthropic (not :tool, which would poison the next turn).
    tool_msg = session.messages.find { |m| Array(m.content).any? { |c| c.is_a?(LLM::Function::Return) } }
    expect(tool_msg).not_to be_nil, "expected a message carrying the LLM::Function::Return, none found in session history"
    expect(tool_msg.role.to_s).to eq("user")
  end
end
