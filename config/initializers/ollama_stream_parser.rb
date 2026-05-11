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
    params = {role: :user, model: default_model, stream: true}.merge!(params)
    tools  = resolve_tools(params.delete(:tools))
    params = [params, {format: params[:schema]}, adapt_tools(tools)].inject({}, &:merge!).compact
    role, stream = params.delete(:role), params.delete(:stream)
    params[:stream] = if stream == false
      false
    elsif stream.respond_to?(:<<) || stream == true
      true
    else
      !!stream
    end
    [params, stream, tools, role]
  end
end
