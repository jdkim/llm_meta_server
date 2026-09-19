# SSE writer for the client-orchestrated single-LLM-turn endpoint
# (Api::SingleLlmCallController#create).
#
# Wire format v2 (locked in with the client-orchestration refactor): text and
# thinking chunks are named events, so the browser can listen for them with
# `EventSource#addEventListener` rather than routing everything through the
# default `onmessage` handler. Contrast with the legacy Api::ChatStreams SSE
# feed, which writes untagged `data:` events for text and consequently mixes
# them with any other unnamed streams — see SseWriter#<< for the base shape.
#
# Event catalog for /api/…/single_llm_call:
#   text_delta      { delta: "…" }
#   thinking_delta  { delta: "…" }
#   tool_call       { tool_call: { id, name, arguments } }  # one per call, post-stream
#   phase           { name: "thinking" | "tool_execution" }  # inherited
#   done            { content, finish_reason }              # emitted by controller
#   error           { code, message }                       # inherited
class SingleLlmCallSseWriter < SseWriter
  def <<(chunk)
    return self if chunk.nil? || chunk.empty?
    event("text_delta", { delta: chunk.to_s })
    self
  end

  def thinking(chunk)
    return self if chunk.nil? || chunk.empty?
    event("thinking_delta", { delta: chunk.to_s })
    self
  end

  def tool_call(call)
    event("tool_call", { tool_call: call })
  end
end
