# frozen_string_literal: true

# Some models write their reasoning INLINE in the ordinary content stream,
# wrapped in delimiters, instead of putting it in a separate field. Left alone
# it lands in the answer bubble.
#
# Two cases seen in production here:
#
#   gpt-oss on Bedrock  <reasoning>…</reasoning>, many blocks, one per chunk.
#     One turn stored 12,212 characters of content beginning "<reasoning>We
#     need to interpret…" with the reasoning column empty.
#
#   medgemma / gemma    <unused94> thought\n…<unused95>, a single leading
#     block; the answer follows the closing token. Gemma's thought markers.
#
# llm.rb adds neither, and neither provider offers a parameter that separates
# the channel, so the split happens here.
#
# SCOPED BY MODEL ON PURPOSE. LiteLLM shipped the gpt-oss split unconditionally
# for Bedrock and destroyed content: models there that already use
# reasoning_content properly (GPT-5.6, Grok) had a legitimate leading
# "<reasoning>" stripped from their answers. A model absent from DELIMITERS is
# passed through untouched.
module InlineReasoning
  # model_id fragment => [open, close]
  DELIMITERS = {
    "gpt-oss" => [ "<reasoning>", "</reasoning>" ],
    "gemma"   => [ "<unused94>",  "<unused95>" ]   # covers medgemma
  }.freeze

  def self.delimiters_for(model_id)
    id = model_id.to_s
    _, pair = DELIMITERS.find { |fragment, _| id.include?(fragment) }
    pair
  end

  def self.applies_to?(model_id)
    !delimiters_for(model_id).nil?
  end

  # Wraps a streaming sink so reasoning reaches sink.thinking instead of the
  # content channel. Returns the sink untouched for every other model.
  def self.wrap(sink, model_id)
    pair = delimiters_for(model_id)
    return sink if sink.nil? || pair.nil?

    Sink.new(sink, *pair)
  end

  # The non-streaming counterpart: the facade reads final text from
  # response.choices[-1].content, which carries the delimiters too.
  # Returns [content_without_reasoning, reasoning_text].
  def self.split(text, model_id)
    open_tag, close_tag = delimiters_for(model_id)
    return [ text, nil ] if open_tag.nil?

    body = text.to_s
    return [ text, nil ] unless body.include?(open_tag)

    o, c = Regexp.escape(open_tag), Regexp.escape(close_tag)
    reasoning = body.scan(/#{o}(.*?)#{c}/m).flatten.join
    # An unclosed trailing block means the turn was cut mid-thought; drop it
    # rather than leaking a half delimiter into the answer.
    content = body.gsub(/#{o}.*?#{c}/m, "").sub(/#{o}.*\z/m, "")
    [ content, reasoning.presence ]
  end

  def self.strip(text, model_id)
    split(text, model_id).first
  end

  # Streaming state machine. Tags can split across network chunks, so a
  # trailing fragment that could still become a tag is held back rather than
  # emitted — otherwise "<reas" reaches the bubble and the rest is miscounted.
  class Sink < SimpleDelegator
    def initialize(sink, open_tag, close_tag)
      super(sink)
      @open = open_tag
      @close = close_tag
      @max_partial = [ @open.length, @close.length ].max - 1
      @buffer = +""
      @inside = false
    end

    def <<(delta)
      @buffer << delta.to_s
      drain!
      self
    end

    # Emits whatever is held back. Call once the provider stream is finished,
    # or a partial tag at the very end is never shown.
    def flush!
      emit(@buffer, @inside)
      @buffer = +""
      self
    end

    private

    def drain!
      loop do
        tag = @inside ? @close : @open
        index = @buffer.index(tag)

        if index
          emit(@buffer[0, index], @inside)
          @buffer = @buffer[(index + tag.length)..] || +""
          @inside = !@inside
        else
          safe = safe_length
          emit(@buffer[0, safe], @inside) if safe.positive?
          @buffer = @buffer[safe..] || +""
          break
        end
      end
    end

    # How much of the buffer cannot possibly be the start of a tag.
    def safe_length
      first_possible = [ @buffer.length - @max_partial, 0 ].max
      (first_possible...@buffer.length).each do |i|
        fragment = @buffer[i..]
        return i if @open.start_with?(fragment) || @close.start_with?(fragment)
      end
      @buffer.length
    end

    def emit(text, as_reasoning)
      return if text.nil? || text.empty?

      if as_reasoning
        __getobj__.thinking(text) if __getobj__.respond_to?(:thinking)
      else
        __getobj__ << text
      end
    end
  end
end
