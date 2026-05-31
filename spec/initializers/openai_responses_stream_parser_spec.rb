require "rails_helper"

# Tests for the LLM::OpenAI::Responses::StreamParser monkey-patch in
# config/initializers/openai_responses_stream_parser.rb. Stock llm.rb only
# handles `response.output_text.delta` for streaming content. The patch
# adds routing for `response.reasoning_summary_text.delta` to sink.thinking
# and treats the surrounding reasoning-summary lifecycle events as no-ops.
RSpec.describe LLM::OpenAI::Responses::StreamParser do
  class OpenAIResponsesTestSink
    attr_reader :content_calls, :thinking_calls
    def initialize
      @content_calls = []
      @thinking_calls = []
    end
    def <<(chunk);       @content_calls << chunk;  end
    def thinking(chunk); @thinking_calls << chunk; end
  end

  let(:sink) { OpenAIResponsesTestSink.new }
  let(:parser) { described_class.new(sink) }

  it "routes response.reasoning_summary_text.delta chunks to sink.thinking" do
    parser.parse!({ "type" => "response.reasoning_summary_text.delta", "delta" => "I need to think about this" })
    parser.parse!({ "type" => "response.reasoning_summary_text.delta", "delta" => " more carefully" })

    expect(sink.thinking_calls).to eq([ "I need to think about this", " more carefully" ])
    expect(sink.content_calls).to be_empty
  end

  it "still routes response.output_text.delta to sink.<< (regression check on the unmodified path)" do
    # Seed the body slots the upstream parser expects.
    parser.parse!({ "type" => "response.output_item.added", "output_index" => 0,
                    "item" => { "type" => "message", "content" => [] } })
    parser.parse!({ "type" => "response.content_part.added", "output_index" => 0,
                    "content_index" => 0, "part" => { "type" => "output_text", "text" => "" } })

    parser.parse!({ "type" => "response.output_text.delta",
                    "output_index" => 0, "content_index" => 0, "delta" => "Hello" })
    parser.parse!({ "type" => "response.output_text.delta",
                    "output_index" => 0, "content_index" => 0, "delta" => " world" })

    expect(sink.content_calls).to eq([ "Hello", " world" ])
    expect(sink.thinking_calls).to be_empty
  end

  it "tolerates the surrounding reasoning-summary lifecycle events as no-ops" do
    parser.parse!({ "type" => "response.reasoning_summary_part.added", "summary_index" => 0 })
    parser.parse!({ "type" => "response.reasoning_summary_text.delta", "delta" => "thought" })
    parser.parse!({ "type" => "response.reasoning_summary_text.done", "text" => "thought" })
    parser.parse!({ "type" => "response.reasoning_summary_part.done", "summary_index" => 0 })

    expect(sink.thinking_calls).to eq([ "thought" ])
    expect(sink.content_calls).to be_empty
  end

  it "is backwards-compatible with a sink that doesn't implement #thinking" do
    bare_sink = Class.new { def <<(x); (@buf ||= +"") << x.to_s; end; def buf; @buf || ""; end }.new
    bare_parser = described_class.new(bare_sink)

    bare_parser.parse!({ "type" => "response.reasoning_summary_text.delta", "delta" => "would crash if forwarded" })
    bare_parser.parse!({ "type" => "response.output_item.added", "output_index" => 0,
                         "item" => { "type" => "message", "content" => [] } })
    bare_parser.parse!({ "type" => "response.content_part.added", "output_index" => 0,
                         "content_index" => 0, "part" => { "type" => "output_text", "text" => "" } })
    bare_parser.parse!({ "type" => "response.output_text.delta",
                         "output_index" => 0, "content_index" => 0, "delta" => "ok" })

    expect(bare_sink.buf).to eq("ok")
  end
end
