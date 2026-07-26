require "rails_helper"

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
