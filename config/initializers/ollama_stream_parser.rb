# Patch llm.rb's Ollama provider so that `stream: false` is honored.
#
# Stock normalize_complete_params drops `stream: false`, which causes Ollama
# to default to streaming for every chat call. The streaming response is then
# parsed by Ollama::StreamParser, which only accumulates `content` from
# subsequent chunks and silently drops any `tool_calls` emitted after the
# first message chunk. Result: tool-only completions (e.g. qwen3) lose
# their tool_calls and the assistant message looks empty.
#
# The fix: when we explicitly pass `stream: false`, propagate it into the
# request body so Ollama returns one complete JSON response, which is then
# parsed via the regular non-streaming path (no chunk accumulation needed).

require "llm/providers/ollama"

class LLM::Ollama
  private

  def normalize_complete_params(params)
    params = { role: :user, model: default_model, stream: true }.merge!(params)
    tools  = resolve_tools(params.delete(:tools))
    params = [ params, { format: params[:schema] }, adapt_tools(tools) ].inject({}, &:merge!).compact
    role, stream = params.delete(:role), params.delete(:stream)
    params[:stream] = if stream == false
      false
    elsif stream.respond_to?(:<<) || stream == true
      true
    else
      !!stream
    end
    [ params, stream, tools, role ]
  end
end

# Ollama thinking-mode support, and tool_calls accumulation.
#
# The `stream: false` patch above fixes only the turns we send non-streamed.
# LlmRbFacade streams every tool round after turn 1, and there the accumulator
# below still applied: it copied the first `message` chunk wholesale and then
# appended only `content`, so any `tool_calls` arriving in a later chunk were
# dropped. Models write a sentence before acting, so the call almost always
# lands in a later chunk — which is why a streamed conversation made exactly
# one tool call (turn 1, non-streamed) and never another. Verified against
# qwen3.8:27b: identical prompt and tools gave session.functions=1
# non-streamed and 0 streamed, while Ollama's own wire output carried the
# tool_call in both modes. Merging tool_calls below took the same TogoMCP
# prompt from 1 tool call to a full research loop.
#
# When the upstream model emits thinking content (qwen3 etc. with `think: true`),
# Ollama splits each chunk into two siblings: `message.thinking` and
# `message.content`. Stock llm.rb only reads `content`, dropping the thinking
# bytes on the floor. This patch additionally forwards thinking bytes to a
# *separate* method on the sink (`sink.thinking(delta)`) when the sink
# supports it. The SseWriter implements that method as a distinct
# `event: thinking` SSE frame so downstream consumers can render thinking
# separately from final content.
class LLM::Ollama::StreamParser
  private

  def merge!(chunk)
    chunk.each do |key, value|
      if key == "message"
        if @body[key]
          @body[key]["content"] = @body[key]["content"].to_s + value["content"].to_s
          # Ollama emits tool_calls in whichever chunk the model produces them,
          # which is rarely the first one. Accumulate rather than discard.
          calls = value["tool_calls"]
          if calls.is_a?(Array) && calls.any?
            @body[key]["tool_calls"] = Array(@body[key]["tool_calls"]) + calls
          end
        else
          @body[key] = value
        end
        if @io.respond_to?(:<<) && value["content"].to_s.length.positive?
          @io << value["content"]
        end
        if @io.respond_to?(:thinking) && value["thinking"].to_s.length.positive?
          @io.thinking(value["thinking"])
        end
      else
        @body[key] = value
      end
    end
  end
end
