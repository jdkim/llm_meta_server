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

  it "stays backwards-compatible with a sink that doesn't implement #thinking" do
    bare_sink = Class.new { def <<(x); (@buf ||= +"") << x.to_s; end; def buf; @buf || ""; end }.new
    bare_parser = described_class.new(bare_sink)

    bare_parser.parse!({ "message" => { "thinking" => "this would crash if forwarded", "content" => "ok" }, "done" => true })

    expect(bare_sink.buf).to eq("ok")
  end
end
