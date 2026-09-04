require "rails_helper"

# Guards the 2026-09-03 incident: qwen3.6:35b-fast made one tool call, then
# spent 10m51s emitting 87,961 characters that repeated "**Tool Calls:**" 420
# times. The tool-iteration cap did not apply (one iteration ran) and no read
# timeout fired, because bytes kept arriving the whole time.
RSpec.describe TurnBudgetSink do
  # A clock we control — the point is elapsed wall time, not sleeping for it.
  let(:clock) { class_double(Time, now: Time.zone.parse("2026-09-03 16:00:00")) }
  let(:inner) { [] }

  def sink(seconds: 300)
    described_class.new(inner, seconds: seconds, clock: clock)
  end

  def advance(seconds)
    allow(clock).to receive(:now).and_return(Time.zone.parse("2026-09-03 16:00:00") + seconds)
  end

  it "passes chunks through while inside the budget" do
    s = sink
    advance(299)

    s << "hello"

    expect(inner).to eq([ "hello" ])
  end

  it "stops a generation that runs past the budget" do
    s = sink
    advance(301)

    expect { s << "still going" }.to raise_error(described_class::Exceeded, /300s/)
  end

  it "aborts mid-stream, not only between chunks" do
    s = sink
    s << "first"
    advance(400)

    # The runaway was inside ONE generation, so the check has to bite where
    # the bytes arrive; a between-iterations check would never have fired.
    expect { s << "second" }.to raise_error(described_class::Exceeded)
    expect(inner).to eq([ "first" ])
  end

  it "applies the budget to thinking deltas too" do
    thinker = Class.new { def thinking(_d) = nil }.new
    s = described_class.new(thinker, seconds: 300, clock: clock)
    advance(301)

    expect { s.thinking("...") }.to raise_error(described_class::Exceeded)
  end

  it "forwards other sink methods untouched" do
    writer = Class.new { def close = :closed }.new
    s = described_class.new(writer, seconds: 300, clock: clock)

    expect(s.close).to eq(:closed)
    expect(s).to respond_to(:close)
  end

  it "is not double-wrapped when the facade is re-entered" do
    s = sink
    expect(described_class.new(s, seconds: 300, clock: clock)).to be_a(described_class)
    # LlmRbFacade#stream! skips wrapping when the sink already is one.
    expect(LlmRbFacade.singleton_class::TURN_BUDGET_SECONDS).to be_positive
  end
end
