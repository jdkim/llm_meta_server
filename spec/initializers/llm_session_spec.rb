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

# Behaviors added to LLM::Session by config/initializers/llm_session.rb.
# These monkey-patch upstream methods, so the specs verify the whole
# session-level behavior — not just the private helpers — to catch drift
# if upstream ever changes their signatures.
RSpec.describe LLM::Session, "monkey-patched extract_tool_calls" do
  # Regression: an Ollama-shaped tool_call whose arguments are wrapped in
  # LLM::Object was serializing to the wire as `[["names",...]]` (JSON
  # array of pairs) instead of `{"names":...}`. Root cause: Ruby's
  # Hash#to_json doesn't recursively call `.to_json` on LLM::Object
  # values — it iterates them via each_pair. Fix: coerce_tool_arguments
  # normalizes to a plain Hash before returning from normalize_tool_call.
  describe "coerce_tool_arguments (via normalize_tool_call)" do
    let(:session_class) { LLM::Session }

    def normalize(raw_args)
      # Build a minimal tc-like Struct matching what OpenAI adapters expose
      # (id/name/arguments methods). arguments is what we're testing.
      tc = Struct.new(:id, :name, :arguments).new("call_1", "add_dictionaries", raw_args)
      session_class.allocate.send(:normalize_tool_call, tc)
    end

    it "leaves a plain Hash alone" do
      out = normalize({ "names" => [ "uberon" ] })
      expect(out[:arguments]).to eq({ "names" => [ "uberon" ] })
    end

    it "unwraps LLM::Object arguments so nested JSON serialization stays object-shaped" do
      wrapped = LLM::Object.from(names: [ "uberon", "cellosaurus" ])
      out = normalize(wrapped)
      expect(out[:arguments]).to be_a(Hash)
      # The critical assertion — nested-in-hash JSON serialization must
      # produce an object, not an array-of-pairs. This is the wire shape
      # the client-orchestrated JS dispatcher relies on.
      wire = { tool_call: out }.to_json
      expect(JSON.parse(wire)).to eq(
        "tool_call" => { "id" => "call_1", "name" => "add_dictionaries",
                          "arguments" => { "names" => [ "uberon", "cellosaurus" ] } }
      )
    end

    it "coerces nil to {}" do
      expect(normalize(nil)[:arguments]).to eq({})
    end

    it "passes through non-hash values that don't respond to to_h (defensive)" do
      expect(normalize("raw string")[:arguments]).to eq("raw string")
    end
  end
end

RSpec.describe LLM::Message, "monkey-patched functions (history replay for client-orchestrated flow)" do
  # Regression for Phase 2 · Class 2: when the widget round-trips a remote
  # MCP tool_call, round 2's request contains the assistant-with-tool_calls
  # turn as history. Reconstructed messages have no wrapping response, so
  # LLM::Message#available_tools returns []. Upstream #functions then does
  # `available_tools.find { ... }.dup.tap { _1.id = fn.id }` → NoMethodError
  # for `id=` on nil. The initializer's override handles the nil-find case.
  it "builds functions directly from tool_calls when no wrapping response provides available_tools" do
    msg = LLM::Message.new("assistant", "", tool_calls: [
      { "id" => "call_1", "name" => "list_dictionaries", "arguments" => {} }
    ])
    fns = msg.functions
    expect(fns.length).to eq(1)
    expect(fns.first.name.to_s).to eq("list_dictionaries")
    expect(fns.first.id).to eq("call_1")
    # Marked as already-called so Session#functions.select(&:pending?) skips it —
    # client-orchestrated flow: the CLIENT dispatched, hub must not re-execute.
    expect(fns.first.pending?).to eq(false)
  end

  it "keeps the upstream hub-orchestrated path — freshly-emitted tool_calls stay pending" do
    # Simulate a freshly-emitted tool_call: available_tools IS populated
    # (there's a wrapping response). Function must remain PENDING so the
    # hub can dispatch it.
    matching_tool = LLM::Function.new("some_tool")
    # Fake a response object exposing __tools__:
    fake_response = Struct.new(:__tools__).new([ matching_tool ])
    msg = LLM::Message.new("assistant", "",
                            tool_calls: [ { "id" => "call_x", "name" => "some_tool", "arguments" => { "q" => "hi" } } ],
                            response: fake_response)
    fns = msg.functions
    expect(fns.length).to eq(1)
    expect(fns.first.name.to_s).to eq("some_tool")
    expect(fns.first.pending?).to eq(true), "freshly-emitted functions must remain pending"
  end
end
