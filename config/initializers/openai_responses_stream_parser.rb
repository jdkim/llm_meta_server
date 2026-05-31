# OpenAI Responses-API thinking-mode support.
#
# Stock llm.rb's Responses::StreamParser only handles
# `response.output_text.delta` for streamed content. When the request
# includes `reasoning: {summary: "auto"}` (LlmRbFacade adds this for any
# catalog entry with `endpoint: responses` — currently the GPT-5 family),
# OpenAI also emits `response.reasoning_summary_text.delta` chunks with
# the model's reasoning summary. This patch:
#
#   * Routes those deltas to `sink.thinking(...)` so the SSE `event:
#     thinking` channel receives them (matching the UI block that
#     Gemini + Claude + Ollama already populate).
#   * Tolerates the surrounding lifecycle events (summary_part.added /
#     done, summary_text.done) as no-ops so the parser doesn't drop them
#     into the body's unstructured catch.

require "llm/providers/openai"
require "llm/providers/openai/responses/stream_parser"

class LLM::OpenAI::Responses::StreamParser
  private

  alias_method :__original_handle_event_for_thinking, :handle_event

  def handle_event(chunk)
    case chunk["type"]
    when "response.reasoning_summary_text.delta"
      delta_text = chunk["delta"].to_s
      if @io.respond_to?(:thinking) && delta_text.length.positive?
        @io.thinking(delta_text)
      end
    when "response.reasoning_summary_part.added",
         "response.reasoning_summary_part.done",
         "response.reasoning_summary_text.done"
      # Lifecycle markers around the reasoning summary; nothing to do.
    else
      __original_handle_event_for_thinking(chunk)
    end
  end
end
