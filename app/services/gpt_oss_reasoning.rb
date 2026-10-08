# frozen_string_literal: true

# Bedrock's OpenAI-compatible Chat Completions endpoint inlines gpt-oss's
# reasoning into the ordinary content stream, wrapped in <reasoning> tags,
# instead of putting it in a separate field. Left alone it lands in the answer
# bubble: one production turn stored 12,212 characters of content beginning
# "<reasoning>We need to interpret..." with an empty reasoning column.
#
# llm.rb does not add these tags and AWS offers no parameter that separates the
# channel (`reasoning_effort` changes how much the model thinks, not where the
# text goes), so the split has to happen here.
#
# SCOPED TO gpt-oss ON PURPOSE. LiteLLM shipped this unconditionally for Bedrock
# and destroyed content: other models there (GPT-5.6, Grok) already use
# reasoning_content properly, so an answer that legitimately *began* with the
# literal text "<reasoning>" had it silently stripped. Only gpt-oss inlines.
module GptOssReasoning
  OPEN  = "<reasoning>"
  CLOSE = "</reasoning>"

  def self.applies_to?(model_id)
    model_id.to_s.include?("gpt-oss")
  end

  # Wraps a streaming sink so reasoning reaches sink.thinking instead of the
  # content channel. Returns the sink untouched for every other model.
  def self.wrap(sink, model_id)
    return sink if sink.nil? || !applies_to?(model_id)

    Sink.new(sink)
  end

  # The non-streaming counterpart: the facade reads final text from
  # response.choices[-1].content, which carries the tags too.
  # Returns [content_without_reasoning, reasoning_text].
  def self.split(text, model_id)
    return [ text, nil ] unless applies_to?(model_id)

    body = text.to_s
    return [ text, nil ] unless body.include?(OPEN)

    reasoning = body.scan(/#{Regexp.escape(OPEN)}(.*?)#{Regexp.escape(CLOSE)}/m).flatten.join
    # An unclosed trailing block means the turn was cut mid-thought; drop it
    # from the content rather than leaking a half tag into the answer.
    content = body.gsub(/#{Regexp.escape(OPEN)}.*?#{Regexp.escape(CLOSE)}/m, "")
                  .sub(/#{Regexp.escape(OPEN)}.*\z/m, "")
    [ content, reasoning.presence ]
  end

  def self.strip(text, model_id)
    split(text, model_id).first
  end

  # Streaming state machine. Tags can split across network chunks, so a
  # trailing fragment that could still become a tag is held back rather than
  # emitted — otherwise "<reas" reaches the bubble and the rest is miscounted.
  class Sink < SimpleDelegator
    MAX_PARTIAL = [ OPEN.length, CLOSE.length ].max - 1

    def initialize(sink)
      super
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
        tag = @inside ? CLOSE : OPEN
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
      first_possible = [ @buffer.length - MAX_PARTIAL, 0 ].max
      (first_possible...@buffer.length).each do |i|
        fragment = @buffer[i..]
        return i if OPEN.start_with?(fragment) || CLOSE.start_with?(fragment)
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
