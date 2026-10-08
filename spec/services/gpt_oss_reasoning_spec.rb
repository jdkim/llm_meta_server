require "rails_helper"

# Bedrock inlines gpt-oss reasoning into the content stream wrapped in
# <reasoning> tags. Production evidence: a turn stored 12,212 characters
# beginning "<reasoning>We need to interpret..." with reasoning column empty,
# and 18 tag pairs back to back — one per streamed chunk.
RSpec.describe GptOssReasoning do
  # Collects what each channel received, so the split is observable.
  let(:collector) do
    Class.new do
      attr_reader :content, :reasoning
      def initialize = (@content = +""; @reasoning = +"")
      def <<(text) = (@content << text; self)
      def thinking(text) = (@reasoning << text)
    end.new
  end

  def stream(text, model_id: "openai.gpt-oss-120b-1:0", chunk: nil)
    sink = described_class.wrap(collector, model_id)
    pieces = chunk ? text.chars.each_slice(chunk).map(&:join) : [ text ]
    pieces.each { |p| sink << p }
    sink.flush! if sink.respond_to?(:flush!)
    sink
  end

  describe "scoping" do
    # LiteLLM shipped this unconditionally and destroyed content: on Bedrock,
    # models other than gpt-oss use reasoning_content properly, so an answer
    # legitimately starting with the literal "<reasoning>" lost that text.
    it "leaves non-gpt-oss models completely alone" do
      stream("<reasoning>not really</reasoning>answer", model_id: "openai.gpt-5-6")
      expect(collector.content).to eq("<reasoning>not really</reasoning>answer")
      expect(collector.reasoning).to be_empty
    end

    it "returns the original sink object for other models" do
      expect(described_class.wrap(collector, "anthropic.claude")).to equal(collector)
    end

    it "tolerates a nil sink" do
      expect(described_class.wrap(nil, "openai.gpt-oss-120b-1:0")).to be_nil
    end
  end

  describe "streaming" do
    it "routes reasoning to thinking and keeps the answer in content" do
      stream("<reasoning>thinking hard</reasoning>The answer is 42.")
      expect(collector.content).to eq("The answer is 42.")
      expect(collector.reasoning).to eq("thinking hard")
    end

    it "handles the many back-to-back blocks Bedrock actually sends" do
      stream("<reasoning>a</reasoning><reasoning>b</reasoning>text<reasoning>c</reasoning>!")
      expect(collector.content).to eq("text!")
      expect(collector.reasoning).to eq("abc")
    end

    # The case that makes this a state machine rather than a regex: a tag can
    # straddle a network chunk boundary.
    it "survives tags split across chunks, at every boundary" do
      (1..6).each do |size|
        collector.content.clear
        collector.reasoning.clear
        stream("<reasoning>why</reasoning>answer", chunk: size)
        expect(collector.content).to eq("answer"), "chunk size #{size}"
        expect(collector.reasoning).to eq("why"), "chunk size #{size}"
      end
    end

    it "never leaks a partial tag into the answer mid-stream" do
      sink = described_class.wrap(collector, "openai.gpt-oss-120b-1:0")
      sink << "hello<reas"
      expect(collector.content).to eq("hello")   # the fragment is held back
      sink << "oning>secret</reasoning> world"
      sink.flush!
      expect(collector.content).to eq("hello world")
      expect(collector.reasoning).to eq("secret")
    end

    it "emits a held fragment on flush rather than swallowing it" do
      sink = described_class.wrap(collector, "openai.gpt-oss-120b-1:0")
      sink << "done<rea"
      sink.flush!
      expect(collector.content).to eq("done<rea")
    end

    it "treats text that merely resembles a tag as content" do
      stream("use <reason> and <reasoningX> normally")
      expect(collector.content).to eq("use <reason> and <reasoningX> normally")
      expect(collector.reasoning).to be_empty
    end

    it "passes content through untouched when there is no reasoning at all" do
      stream("just an answer")
      expect(collector.content).to eq("just an answer")
      expect(collector.reasoning).to be_empty
    end
  end

  describe ".split (the stored content path)" do
    it "separates content from reasoning" do
      content, reasoning = described_class.split(
        "<reasoning>a</reasoning>Answer<reasoning>b</reasoning>.", "openai.gpt-oss-120b-1:0"
      )
      expect(content).to eq("Answer.")
      expect(reasoning).to eq("ab")
    end

    # A turn cut off mid-thought (the 900s budget, a dropped connection) leaves
    # an unclosed block; better to drop it than leak half a tag into the answer.
    it "drops an unclosed trailing block" do
      content, = described_class.split("Answer so far<reasoning>cut off", "openai.gpt-oss-120b-1:0")
      expect(content).to eq("Answer so far")
    end

    it "leaves other models untouched" do
      text = "<reasoning>keep me</reasoning>hi"
      expect(described_class.split(text, "openai.gpt-5-6")).to eq([ text, nil ])
    end
  end
end
