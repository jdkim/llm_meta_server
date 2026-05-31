# Gemini thinking-mode support.
#
# When the request includes generationConfig.thinkingConfig.includeThoughts:
# true (LlmRbFacade#apply_provider_defaults adds this by default for the
# google family), Gemini emits each chunk's content parts with a `thought:
# true` flag distinguishing reasoning from final-content text. Stock
# llm.rb concatenates everything as if it were one text stream, so:
#
#   * The streaming UI sees thinking bytes intermixed with final content.
#   * The persisted assistant message includes the reasoning verbatim.
#
# This patch routes thought-flagged text to `sink.thinking(...)` (matching
# the SSE `event: thinking` channel SseWriter exposes) and skips them in
# the assembled @body, so neither the streamed content nor the saved
# message includes the thoughts.

require "llm/providers/gemini"

class LLM::Gemini::StreamParser
  private

  def merge_text!(parts, delta)
    if delta["thought"]
      # Ephemeral thinking — emit on the separate channel, do NOT merge
      # into @body so the assembled response stays content-only.
      if @io.respond_to?(:thinking) && delta["text"].to_s.length.positive?
        @io.thinking(delta["text"])
      end
      return
    end

    last_existing_part = parts.last
    text = delta["text"]
    # Coalesce only with other content parts (not thoughts we may have
    # filtered through). Use `=` with concat rather than `<<` because
    # the stored string may be aliased into the sink's captured deltas
    # — mutating it would retroactively corrupt earlier sink entries.
    if last_existing_part.is_a?(Hash) && last_existing_part["text"] && !last_existing_part["thought"]
      last_existing_part["text"] = last_existing_part["text"].to_s + text.to_s
      @io << text if @io.respond_to?(:<<)
    else
      parts << delta
      @io << text if @io.respond_to?(:<<)
    end
  end
end
