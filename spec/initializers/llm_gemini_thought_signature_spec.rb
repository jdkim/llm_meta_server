require "rails_helper"

# Guards config/initializers/llm_gemini_thought_signature.rb — the patch that
# preserves Gemini's `thoughtSignature` (on functionCall parts) across the
# response → session-history → next-request round trip. Without this,
# multi-turn tool loops on thinking-capable Gemini Pro models 400 on turn 2
# with "Function call is missing a thought_signature in functionCall parts."
RSpec.describe "LLM::Gemini thought_signature preservation patch" do
  describe "response adapter (adapt_choices)" do
    # Construct a fake response body shaped like Gemini's real payload.
    # The key property: parts contain `functionCall` alongside `thoughtSignature`.
    let(:body) do
      LLM::Object.from(
        candidates: [
          {
            content: {
              role: "model",
              parts: [
                { "text" => "let me search" },
                {
                  "thoughtSignature" => "SIGNATURE_ABC123",
                  "functionCall" => { "name" => "youtube_search", "args" => { "q" => "fable" } }
                }
              ]
            },
            finishReason: "STOP"
          }
        ],
        usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 20, thoughtsTokenCount: 5, totalTokenCount: 35 },
        modelVersion: "gemini-3-1-pro"
      )
    end

    let(:response) do
      # ResponseAdapter is a module extended onto LLM::Response. Build one
      # by hand so we can invoke adapt_choices without hitting the wire.
      res = LLM::Response.new(nil)
      res.instance_variable_set(:@body, body)
      res.define_singleton_method(:body) { @body }
      res.extend(LLM::Gemini::ResponseAdapter::Completion)
      res
    end

    it "populates extra[:original_parts] with the full parts (thoughtSignature preserved)" do
      msg = response.messages.first
      parts = msg.extra[:original_parts]

      expect(parts.length).to eq(1)
      expect(parts.first["thoughtSignature"]).to eq("SIGNATURE_ABC123")
      expect(parts.first["functionCall"]["name"]).to eq("youtube_search")
    end

    it "still populates extra[:original_tool_calls] (backward compat with the older code path)" do
      msg = response.messages.first
      tool_calls = msg.extra[:original_tool_calls]

      expect(tool_calls.length).to eq(1)
      expect(tool_calls.first["name"]).to eq("youtube_search")
      # The inner dict does NOT carry thoughtSignature — it's a sibling field.
      expect(tool_calls.first["thoughtSignature"]).to be_nil
    end

    it "still extracts text content from non-function parts" do
      msg = response.messages.first
      expect(msg.content).to eq("let me search")
    end

    it "preserves thoughtSignature on multiple parallel functionCall parts" do
      # Realistic Gemini Pro shape — the model often emits 2+ tool calls in
      # a single response ("search these in parallel"). Each part has its
      # own thoughtSignature and each must round-trip independently.
      multi_body = LLM::Object.from(
        candidates: [ {
          content: {
            role: "model",
            parts: [
              { "text" => "looking these up in parallel" },
              { "thoughtSignature" => "SIG_A", "functionCall" => { "name" => "search_a", "args" => { "q" => "one" } } },
              { "thoughtSignature" => "SIG_B", "functionCall" => { "name" => "search_b", "args" => { "q" => "two" } } },
              # Third call with NO signature — should still survive as a part,
              # just without a signature field. Realistic if Gemini ever emits
              # partial signatures.
              { "functionCall" => { "name" => "search_c", "args" => { "q" => "three" } } }
            ]
          },
          finishReason: "STOP"
        } ],
        usageMetadata: {}, modelVersion: "gemini-3-1-pro"
      )

      multi_response = LLM::Response.new(nil)
      multi_response.instance_variable_set(:@body, multi_body)
      multi_response.define_singleton_method(:body) { @body }
      multi_response.extend(LLM::Gemini::ResponseAdapter::Completion)

      parts = multi_response.messages.first.extra[:original_parts]

      expect(parts.length).to eq(3)
      expect(parts.map { _1["functionCall"]["name"] }).to eq(%w[search_a search_b search_c])
      expect(parts.map { _1["thoughtSignature"] }).to eq([ "SIG_A", "SIG_B", nil ])
      # And tool_calls (backward-compat field) still enumerates all three.
      expect(multi_response.messages.first.extra[:tool_calls].map { _1[:name] }).to eq(%w[search_a search_b search_c])
    end
  end

  describe "request adapter (Completion#adapt)" do
    let(:tool_part_with_signature) do
      { "thoughtSignature" => "SIGNATURE_ABC123",
        "functionCall" => { "name" => "youtube_search", "args" => { "q" => "fable" } } }
    end

    def build_message(original_parts:, original_tool_calls:)
      msg = LLM::Message.new("model", "",
        response: nil,
        tool_calls: [ { name: "youtube_search", arguments: { "q" => "fable" } } ],
        original_tool_calls: original_tool_calls,
        original_parts: original_parts)
      msg
    end

    it "emits parts from original_parts when present (with thoughtSignature intact)" do
      msg = build_message(original_parts: [ tool_part_with_signature ], original_tool_calls: [ { "name" => "x" } ])
      result = LLM::Gemini::RequestAdapter::Completion.new(msg).adapt

      expect(result[:role]).to eq("model")
      expect(result[:parts]).to eq([ tool_part_with_signature ])
      expect(result[:parts].first["thoughtSignature"]).to eq("SIGNATURE_ABC123")
    end

    it "falls back to original_tool_calls when original_parts is missing (pre-patch messages)" do
      inner_only = { "name" => "search", "args" => { "q" => "x" } }
      msg = build_message(original_parts: nil, original_tool_calls: [ inner_only ])
      result = LLM::Gemini::RequestAdapter::Completion.new(msg).adapt

      # Wrapped in the old shape — no thoughtSignature, but at least the
      # request goes through (Gemini only enforces this on thinking Pro).
      expect(result[:parts]).to eq([ { "functionCall" => inner_only } ])
    end

    it "falls back to original_tool_calls when original_parts is an empty array" do
      # An empty original_parts must also trigger the fallback, otherwise the
      # request adapter would emit `parts: []` and the API 400s on "content required".
      msg = build_message(original_parts: [], original_tool_calls: [ { "name" => "x" } ])
      result = LLM::Gemini::RequestAdapter::Completion.new(msg).adapt

      expect(result[:parts]).to eq([ { "functionCall" => { "name" => "x" } } ])
    end
  end

  describe "end-to-end round trip (integration)" do
    # Response → adapt → LLM::Message → serialize → outgoing request body.
    # If thoughtSignature makes it through both hops, the whole pipeline works.
    it "preserves thoughtSignature from response through to the outgoing request" do
      body = LLM::Object.from(
        candidates: [ {
          content: {
            role: "model",
            parts: [
              { "thoughtSignature" => "ROUND_TRIP_SIG",
                "functionCall" => { "name" => "test", "args" => {} } }
            ]
          }
        } ],
        usageMetadata: {},
        modelVersion: "gemini-3-1-pro"
      )

      response = LLM::Response.new(nil)
      response.instance_variable_set(:@body, body)
      response.define_singleton_method(:body) { @body }
      response.extend(LLM::Gemini::ResponseAdapter::Completion)

      msg = response.messages.first
      # Simulate what LLM::Bot#talk records — tool_call? checks extra
      allow(msg).to receive(:tool_call?).and_return(true)

      outgoing = LLM::Gemini::RequestAdapter::Completion.new(msg).adapt

      expect(outgoing[:parts].first["thoughtSignature"]).to eq("ROUND_TRIP_SIG")
    end
  end
end
