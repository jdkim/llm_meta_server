require "rails_helper"

# Tests for the SSE framing helper. The wire shape is a contract that the
# test_service frontend (and any other consumer of llm_meta_client) depends
# on, so we pin each event type's exact bytes.
RSpec.describe SseWriter do
  let(:stream) { StringIO.new }
  let(:sse) { described_class.new(stream) }

  describe "#<<" do
    it "writes a delta event with the chunk JSON-wrapped" do
      sse << "Hello"
      expect(stream.string).to eq('data: {"delta":"Hello"}' + "\n\n")
    end

    it "is a no-op for nil and empty chunks (keeps the stream clean)" do
      sse << nil
      sse << ""
      expect(stream.string).to eq("")
    end
  end

  describe "#event" do
    it "writes 'event: <name>\\ndata: <json>\\n\\n'" do
      sse.event("done", { x: 1 })
      expect(stream.string).to eq("event: done\ndata: {\"x\":1}\n\n")
    end
  end

  describe "#phase" do
    it "wraps the phase name as {name: ...}" do
      sse.phase("streaming")
      expect(stream.string).to eq("event: phase\ndata: {\"name\":\"streaming\"}\n\n")
    end
  end

  describe "#thinking" do
    it "emits as a separate 'event: thinking' frame distinct from content deltas" do
      sse.thinking("Let me work this out")
      expect(stream.string).to eq("event: thinking\ndata: {\"delta\":\"Let me work this out\"}\n\n")
    end

    it "is a no-op for nil and empty chunks" do
      sse.thinking(nil)
      sse.thinking("")
      expect(stream.string).to eq("")
    end

    it "does NOT touch the default content-delta channel (no `data:` without an event:)" do
      sse.thinking("just thinking")
      expect(stream.string).not_to match(/\Adata:/m)
    end
  end

  describe "#heartbeat" do
    it "emits an SSE comment line (ignored by EventSource but keeps the TCP connection warm)" do
      sse.heartbeat
      expect(stream.string).to eq(": keepalive\n\n")
    end
  end
end
