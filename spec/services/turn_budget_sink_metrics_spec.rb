require "rails_helper"

# The budget wrapper doubles as the stream's meter: it is the one object that
# sees every content and reasoning delta, whatever the provider or branch.
# Before this, a turn that streamed no reasoning summary and one whose summary
# was lost further down looked identical in the log.
RSpec.describe TurnBudgetSink, "stream metrics" do
  let(:inner) do
    Class.new do
      attr_reader :chunks, :thoughts
      def initialize = (@chunks = []; @thoughts = [])
      def <<(c) = (@chunks << c; self)
      def thinking(d) = @thoughts << d
    end.new
  end

  subject(:sink) { described_class.new(inner, seconds: 300) }

  it "starts at zero" do
    expect(sink.stream_stats).to eq("content=0B reasoning=0deltas/0B")
  end

  it "counts content bytes and still forwards the chunk" do
    sink << "hello"
    sink << " there"

    expect(sink.content_bytes).to eq(11)
    expect(inner.chunks).to eq([ "hello", " there" ])
  end

  it "counts reasoning deltas and bytes, and still forwards them" do
    sink.thinking("abc")
    sink.thinking("de")

    expect(sink.thinking_deltas).to eq(2)
    expect(sink.thinking_bytes).to eq(5)
    expect(inner.thoughts).to eq([ "abc", "de" ])
  end

  it "counts bytes, not characters, so multibyte reasoning isn't undercounted" do
    sink.thinking("日本語")

    expect(sink.thinking_bytes).to eq(9)
  end

  it "distinguishes a turn with no reasoning from one with reasoning" do
    sink << "answer"

    expect(sink.stream_stats).to eq("content=6B reasoning=0deltas/0B")
  end

  it "tolerates an inner sink that has no #thinking" do
    bare = Class.new { def <<(c) = self }.new
    metered = described_class.new(bare, seconds: 300)

    expect { metered.thinking("x") }.not_to raise_error
    expect(metered.thinking_deltas).to eq(1)
  end
end
