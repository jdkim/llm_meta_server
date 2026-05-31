# Anthropic thinking-mode support.
#
# When the request includes `thinking: {type: "enabled", budget_tokens: N}`
# (LlmRbFacade#apply_provider_defaults adds this by default for the
# anthropic family), Claude emits a separate `content_block` of type
# "thinking" with `thinking_delta` events streaming the reasoning text.
# Stock llm.rb's stream parser only handles `text_delta` and
# `input_json_delta`, so:
#
#   * Thinking deltas are dropped silently — UI sees no reasoning.
#   * `signature_delta` events (the per-block signature) accumulate as
#     unknown blocks; harmless but noisy.
#
# This patch:
#   * Routes `thinking_delta` chunks to `sink.thinking(...)` so the SSE
#     `event: thinking` channel receives them (matching the wiring SseWriter
#     already exposes for Gemini and Ollama).
#   * Skips the thinking content block in @body so the assembled response
#     (the assistant message that gets persisted) contains only the final
#     text, not the reasoning.
#   * Tolerates `signature_delta` events as no-ops.

require "llm/providers/anthropic"

class LLM::Anthropic::StreamParser
  private

  def merge!(chunk)
    # Note on visibility: this routing works for Sonnet 4.6 (and presumably
    # Haiku 4.5) — they emit content_block_delta with delta.type ==
    # "thinking_delta" carrying the reasoning text. Opus 4.7 in adaptive
    # mode opens a `type: "thinking"` content block + emits a
    # signature_delta but NO thinking_delta events, so the Reasoning
    # block will stay empty for Opus regardless of output_config.effort.
    # That's an Anthropic-side decision (internal-only reasoning for
    # Opus's adaptive mode), not a parser gap.
    case chunk["type"]
    when "message_start"
      merge_message!(chunk["message"])
    when "content_block_start"
      # Always seed the @body slot so the response adapter's later
      # `parts.select { _1["type"] == "text" }` doesn't trip over a nil
      # entry. Thinking blocks stay as an empty placeholder in @body;
      # their deltas are routed to sink.thinking below (not accumulated
      # into the placeholder), and the response adapter ignores non-text
      # / non-tool_use block types anyway.
      cb = chunk["content_block"]
      @body["content"][chunk["index"]] = cb if cb
    when "content_block_delta"
      delta = chunk["delta"]
      case delta["type"]
      when "text_delta"
        slot = @body["content"][chunk["index"]]
        if slot
          slot["text"] = slot["text"].to_s + delta["text"].to_s
          @io << delta["text"] if @io.respond_to?(:<<)
        end
      when "thinking_delta"
        if @io.respond_to?(:thinking) && delta["thinking"].to_s.length.positive?
          @io.thinking(delta["thinking"])
        end
        # Intentionally skip @body — thinking is ephemeral.
      when "signature_delta"
        # Per-thinking-block signature; nothing to do downstream.
      when "input_json_delta"
        content = @body["content"][chunk["index"]]
        if content
          if Hash === content["input"]
            content["input"] = chunk["delta"]["partial_json"]
          else
            content["input"] = content["input"].to_s + chunk["delta"]["partial_json"].to_s
          end
        end
      end
    when "message_delta"
      merge_message!(chunk["delta"]) if chunk["delta"]
      extras = chunk.reject { |k, _| k == "type" || k == "delta" }
      merge_message!(extras) unless extras.empty?
    when "content_block_stop"
      content = @body["content"][chunk["index"]]
      if content && content["input"]
        content["input"] = LLM.json.load(content["input"])
      end
    end
  end
end
