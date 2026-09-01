require "rails_helper"

RSpec.describe LLM::Session do
  describe "#normalize_tool_call" do
    let(:session) { described_class.allocate }

    # Regression guard for the "arguments serialized as array-of-pairs" bug
    # (see project_ollama_traps memory and the UBERON-AE chat incident).
    # LLM::Object's own #to_json is correct in isolation, but when nested as
    # a Hash VALUE, Ruby's json encoder ignores custom #to_json and falls
    # back to `each_pair`, emitting `[["k","v"],...]`. That garbled payload
    # then gets displayed in the assistant's "Tool calls" section and
    # persisted into the next turn's LLM context, teaching the model that
    # the call it just made had a broken argument shape.
    it "coerces LLM::Object arguments to Hash so nested JSON encoding stays object-shaped" do
      args = LLM::Object.new(labels: "stomach", dictionary: "UBERON-AE")
      tc = LLM::Object.new(id: "call_1", name: "find_ids", arguments: args)

      normalized = session.send(:normalize_tool_call, tc)

      expect(normalized[:arguments]).to be_a(Hash)
      # The critical assertion: when the normalized tool_call is nested in
      # another Hash (as it is when emitted via SSE and stored in message
      # history), the arguments must still serialize as a JSON object.
      json = { tool_calls: [ normalized ] }.to_json
      expect(json).to include('"arguments":{"labels":"stomach","dictionary":"UBERON-AE"}')
      expect(json).not_to include('[["labels","stomach"]')
    end

    it "handles hash arguments unchanged" do
      tc = LLM::Object.new(id: "call_2", name: "x", arguments: { k: "v" })
      normalized = session.send(:normalize_tool_call, tc)
      expect(normalized[:arguments]).to eq({ k: "v" })
    end

    it "handles nil arguments by returning an empty Hash" do
      tc = LLM::Object.new(id: "call_3", name: "x", arguments: nil)
      normalized = session.send(:normalize_tool_call, tc)
      expect(normalized[:arguments]).to eq({})
    end

    it "handles hash-shaped tc (indexed access) with LLM::Object arguments" do
      # The `else` branch of normalize_tool_call (tc doesn't respond_to :id).
      tc = { "id" => "call_4", "name" => "y",
             "arguments" => LLM::Object.new(a: 1, b: 2) }
      normalized = session.send(:normalize_tool_call, tc)
      expect(normalized[:arguments]).to be_a(Hash)
      expect({ tool_calls: [ normalized ] }.to_json).to include('"arguments":{"a":1,"b":2}')
    end
  end
end
