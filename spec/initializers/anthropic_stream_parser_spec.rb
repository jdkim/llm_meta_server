require "rails_helper"

# Tests for the LLM::Anthropic::StreamParser monkey-patch in
# config/initializers/anthropic_stream_parser.rb. Stock llm.rb only handles
# text_delta and input_json_delta; the patch routes Claude's
# `thinking_delta` events to sink.thinking, tolerates signature_delta as
# a no-op, and excludes the thinking content block from the assembled
# @body so the persisted assistant message contains only the final text.
RSpec.describe LLM::Anthropic::StreamParser do
  class AnthropicTestSink
    attr_reader :content_calls, :thinking_calls
    def initialize
      @content_calls = []
      @thinking_calls = []
    end
    def <<(chunk);       @content_calls << chunk;  end
    def thinking(chunk); @thinking_calls << chunk; end
  end

  let(:sink) { AnthropicTestSink.new }
  let(:parser) { described_class.new(sink) }

  # Drive a typical thinking-enabled response: message_start → thinking
  # block (start + 2 thinking_deltas + signature_delta + stop) → text
  # block (start + 2 text_deltas + stop) → message_delta with stop_reason.
  def drive_thinking_then_text
    parser.parse!({ "type" => "message_start",
                    "message" => { "role" => "assistant", "content" => [] } })
    parser.parse!({ "type" => "content_block_start", "index" => 0,
                    "content_block" => { "type" => "thinking", "thinking" => "" } })
    parser.parse!({ "type" => "content_block_delta", "index" => 0,
                    "delta" => { "type" => "thinking_delta", "thinking" => "let me work this out" } })
    parser.parse!({ "type" => "content_block_delta", "index" => 0,
                    "delta" => { "type" => "thinking_delta", "thinking" => ", step by step" } })
    parser.parse!({ "type" => "content_block_delta", "index" => 0,
                    "delta" => { "type" => "signature_delta", "signature" => "sig-bytes" } })
    parser.parse!({ "type" => "content_block_stop", "index" => 0 })
    parser.parse!({ "type" => "content_block_start", "index" => 1,
                    "content_block" => { "type" => "text", "text" => "" } })
    parser.parse!({ "type" => "content_block_delta", "index" => 1,
                    "delta" => { "type" => "text_delta", "text" => "The answer is" } })
    parser.parse!({ "type" => "content_block_delta", "index" => 1,
                    "delta" => { "type" => "text_delta", "text" => " 42." } })
    parser.parse!({ "type" => "content_block_stop", "index" => 1 })
    parser.parse!({ "type" => "message_delta",
                    "delta" => { "stop_reason" => "end_turn" } })
  end

  it "routes thinking_delta chunks to sink.thinking, in order" do
    drive_thinking_then_text
    expect(sink.thinking_calls).to eq([ "let me work this out", ", step by step" ])
  end

  it "routes text_delta chunks to sink.<<, in order" do
    drive_thinking_then_text
    expect(sink.content_calls).to eq([ "The answer is", " 42." ])
  end

  it "keeps the thinking block as an empty placeholder in @body (so .select doesn't trip on nil)" do
    drive_thinking_then_text
    # All slots are populated — the response adapter does
    # parts.select { _1["type"] == "text" } and would NoMethodError on
    # a nil entry, so we always seed.
    expect(parser.body["content"]).to all(be_a(Hash))

    # The thinking placeholder is present but stays empty (deltas were
    # routed to sink.thinking, not appended to the placeholder).
    thinking_blocks = parser.body["content"].select { |b| b["type"] == "thinking" }
    expect(thinking_blocks.length).to eq(1)
    expect(thinking_blocks.first["thinking"]).to eq("")

    # The final text block carries the full content.
    text_blocks = parser.body["content"].select { |b| b["type"] == "text" }
    expect(text_blocks.length).to eq(1)
    expect(text_blocks.first["text"]).to eq("The answer is 42.")
  end

  it "tolerates signature_delta as a no-op (doesn't emit to either sink channel)" do
    parser.parse!({ "type" => "message_start", "message" => { "role" => "assistant", "content" => [] } })
    parser.parse!({ "type" => "content_block_start", "index" => 0,
                    "content_block" => { "type" => "thinking", "thinking" => "" } })
    parser.parse!({ "type" => "content_block_delta", "index" => 0,
                    "delta" => { "type" => "signature_delta", "signature" => "abc" } })

    expect(sink.thinking_calls).to be_empty
    expect(sink.content_calls).to be_empty
  end

  it "is backwards-compatible with a sink that doesn't implement #thinking" do
    bare_sink = Class.new { def <<(x); (@buf ||= +"") << x.to_s; end; def buf; @buf || ""; end }.new
    bare_parser = described_class.new(bare_sink)
    bare_parser.parse!({ "type" => "message_start", "message" => { "role" => "assistant", "content" => [] } })
    bare_parser.parse!({ "type" => "content_block_start", "index" => 0,
                         "content_block" => { "type" => "thinking", "thinking" => "" } })
    bare_parser.parse!({ "type" => "content_block_delta", "index" => 0,
                         "delta" => { "type" => "thinking_delta", "thinking" => "would crash if forwarded" } })
    bare_parser.parse!({ "type" => "content_block_start", "index" => 1,
                         "content_block" => { "type" => "text", "text" => "" } })
    bare_parser.parse!({ "type" => "content_block_delta", "index" => 1,
                         "delta" => { "type" => "text_delta", "text" => "ok" } })

    expect(bare_sink.buf).to eq("ok")
  end
end
