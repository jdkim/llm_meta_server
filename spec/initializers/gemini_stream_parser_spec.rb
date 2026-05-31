require "rails_helper"

# Tests for the LLM::Gemini::StreamParser monkey-patch in
# config/initializers/gemini_stream_parser.rb. Stock llm.rb treats every
# text part as content; the patch routes `thought: true` parts to
# sink.thinking and excludes them from the assembled @body so the saved
# response doesn't contain reasoning bytes.
RSpec.describe LLM::Gemini::StreamParser do
  class GeminiTestSink
    attr_reader :content_calls, :thinking_calls
    def initialize
      @content_calls = []
      @thinking_calls = []
    end
    def <<(chunk);       @content_calls << chunk;  end
    def thinking(chunk); @thinking_calls << chunk; end
  end

  let(:sink) { GeminiTestSink.new }
  let(:parser) { described_class.new(sink) }

  # Build a Gemini stream chunk with the given content parts.
  def chunk(parts)
    { "candidates" => [ { "index" => 0, "content" => { "parts" => parts } } ] }
  end

  it "routes thought-flagged text to sink.thinking and skips it on the content channel" do
    parser.parse!(chunk([ { "text" => "let me work this out", "thought" => true } ]))
    parser.parse!(chunk([ { "text" => "The answer is 42." } ]))

    expect(sink.thinking_calls).to eq([ "let me work this out" ])
    expect(sink.content_calls).to eq([ "The answer is 42." ])
  end

  it "does NOT include thought-flagged text in the assembled @body" do
    parser.parse!(chunk([ { "text" => "thinking…", "thought" => true } ]))
    parser.parse!(chunk([ { "text" => "Hello" } ]))
    parser.parse!(chunk([ { "text" => " world" } ]))

    parts = parser.body["candidates"][0]["content"]["parts"]
    text  = parts.filter_map { |p| p["text"] }.join
    expect(text).to eq("Hello world")
    expect(text).not_to include("thinking")
  end

  it "interleaves thinking and content chunks without losing either" do
    parser.parse!(chunk([ { "text" => "first thought", "thought" => true } ]))
    parser.parse!(chunk([ { "text" => "part A" } ]))
    parser.parse!(chunk([ { "text" => "second thought", "thought" => true } ]))
    parser.parse!(chunk([ { "text" => " part B" } ]))

    expect(sink.thinking_calls).to eq([ "first thought", "second thought" ])
    expect(sink.content_calls).to eq([ "part A", " part B" ])
    expect(parser.body["candidates"][0]["content"]["parts"]
                 .filter_map { |p| p["text"] }.join).to eq("part A part B")
  end

  it "is backwards-compatible with a sink that doesn't implement #thinking" do
    bare_sink = Class.new { def <<(x); (@buf ||= +"") << x.to_s; end; def buf; @buf || ""; end }.new
    bare_parser = described_class.new(bare_sink)

    bare_parser.parse!(chunk([ { "text" => "this would crash if forwarded", "thought" => true } ]))
    bare_parser.parse!(chunk([ { "text" => "ok" } ]))

    expect(bare_sink.buf).to eq("ok")
  end
end
