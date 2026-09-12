require "rails_helper"

# Tests for the LLM::Ollama::StreamParser monkey-patch in
# config/initializers/ollama_stream_parser.rb. Stock llm.rb drops
# `message.thinking` on the floor; the patch routes those bytes to
# `sink.thinking(...)` when the sink supports it, keeping content
# deltas on the default `sink << ...` channel.
RSpec.describe LLM::Ollama::StreamParser do
  # Sink that records each direction separately so we can assert routing.
  class TestSink
    attr_reader :content_calls, :thinking_calls

    def initialize
      @content_calls = []
      @thinking_calls = []
    end

    def <<(chunk)
      @content_calls << chunk
    end

    def thinking(chunk)
      @thinking_calls << chunk
    end
  end

  let(:sink) { TestSink.new }
  let(:parser) { described_class.new(sink) }

  it "routes a chunk's thinking field to sink.thinking, and content to sink.<<" do
    parser.parse!({ "message" => { "thinking" => "let me think", "content" => "" }, "done" => false })
    parser.parse!({ "message" => { "thinking" => "", "content" => "Hello" }, "done" => false })

    expect(sink.thinking_calls).to eq([ "let me think" ])
    expect(sink.content_calls).to eq([ "Hello" ])
  end

  it "handles a single chunk that carries both thinking and content (some models combine them)" do
    parser.parse!({ "message" => { "thinking" => "first I'll", "content" => "Hi" }, "done" => false })

    expect(sink.thinking_calls).to eq([ "first I'll" ])
    expect(sink.content_calls).to eq([ "Hi" ])
  end

  it "skips empty/blank thinking and content bytes (no spurious empty deltas)" do
    parser.parse!({ "message" => { "thinking" => "", "content" => "" }, "done" => true })

    expect(sink.thinking_calls).to be_empty
    expect(sink.content_calls).to be_empty
  end

  it "accumulates content across chunks in @body for the assembled response" do
    parser.parse!({ "message" => { "thinking" => "", "content" => "Hello" }, "done" => false })
    parser.parse!({ "message" => { "thinking" => "", "content" => " world" }, "done" => true })

    expect(parser.body["message"]["content"]).to eq("Hello world")
  end

  # The accumulator used to copy the first `message` chunk wholesale and then
  # append only `content`, so a tool_call arriving after any text was dropped.
  # Models write a sentence before acting, so that was the usual case — which
  # is why a streamed conversation only ever made its turn-1 tool call.
  describe "tool_calls accumulation" do
    let(:call_a) { { "function" => { "name" => "get_MIE_file", "arguments" => { "db" => "chembl" } } } }
    let(:call_b) { { "function" => { "name" => "run_sparql", "arguments" => { "q" => "SELECT" } } } }

    it "keeps a tool_call that arrives after text chunks" do
      parser.parse!({ "message" => { "content" => "Let me look that up." }, "done" => false })
      parser.parse!({ "message" => { "content" => "", "tool_calls" => [ call_a ] }, "done" => true })

      expect(parser.body["message"]["tool_calls"]).to eq([ call_a ])
      expect(parser.body["message"]["content"]).to eq("Let me look that up.")
    end

    it "keeps a tool_call that arrives in the very first chunk" do
      parser.parse!({ "message" => { "content" => "", "tool_calls" => [ call_a ] }, "done" => true })

      expect(parser.body["message"]["tool_calls"]).to eq([ call_a ])
    end

    it "accumulates tool_calls spread across several chunks" do
      parser.parse!({ "message" => { "content" => "first" }, "done" => false })
      parser.parse!({ "message" => { "content" => "", "tool_calls" => [ call_a ] }, "done" => false })
      parser.parse!({ "message" => { "content" => "", "tool_calls" => [ call_b ] }, "done" => true })

      expect(parser.body["message"]["tool_calls"]).to eq([ call_a, call_b ])
    end

    it "accumulates onto a tool_call that was already in the first chunk" do
      # The first chunk is stored wholesale, so this is the one path where the
      # concat starts from a non-empty list rather than from nil.
      parser.parse!({ "message" => { "content" => "", "tool_calls" => [ call_a ] }, "done" => false })
      parser.parse!({ "message" => { "content" => "then", "tool_calls" => [ call_b ] }, "done" => true })

      expect(parser.body["message"]["tool_calls"]).to eq([ call_a, call_b ])
    end

    it "leaves the key absent when the model called nothing" do
      parser.parse!({ "message" => { "content" => "just an answer" }, "done" => true })

      expect(parser.body["message"]).not_to have_key("tool_calls")
    end

    it "ignores an empty tool_calls array rather than creating the key" do
      parser.parse!({ "message" => { "content" => "a" }, "done" => false })
      parser.parse!({ "message" => { "content" => "b", "tool_calls" => [] }, "done" => true })

      expect(parser.body["message"]).not_to have_key("tool_calls")
    end
  end

  it "stays backwards-compatible with a sink that doesn't implement #thinking" do
    bare_sink = Class.new { def <<(x); (@buf ||= +"") << x.to_s; end; def buf; @buf || ""; end }.new
    bare_parser = described_class.new(bare_sink)

    bare_parser.parse!({ "message" => { "thinking" => "this would crash if forwarded", "content" => "ok" }, "done" => true })

    expect(bare_sink.buf).to eq("ok")
  end
end
