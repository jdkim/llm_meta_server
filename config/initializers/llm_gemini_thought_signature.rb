# Patch llm.rb's Gemini adapters so that `thoughtSignature` fields on
# functionCall response parts survive the response → session-history →
# next-request round trip.
#
# Symptom without this patch (thinking-capable Gemini models only, e.g.
# gemini-3-1-pro): iteration 2 of a multi-turn tool loop 400s with
#   "Function call is missing a thought_signature in functionCall parts.
#   This is required for tools to work correctly ...".
# The API uses thoughtSignature to link the model's reasoning trace across
# turns; echoing it back verbatim is required for thinking-capable Pro-tier
# models. Non-thinking Flash-tier Gemini does not enforce this.
#
# What llm.rb 4.3.1 does wrong:
#   response_adapter/completion.rb line ~56:
#     tools = parts.filter_map { _1["functionCall"] }
#   drops the outer part (holding thoughtSignature) and keeps only the
#   inner functionCall dict.
#
#   request_adapter/completion.rb line ~22:
#     parts: message.extra[:original_tool_calls].map { {"functionCall" => _1} }
#   re-wraps the inner dict — no way to attach thoughtSignature back.
#
# Fix: response adapter also stashes the full outer parts as
# extra[:original_parts]. Request adapter prefers original_parts when
# present, so thoughtSignature (and any other sibling metadata Gemini
# adds later) rides along untouched.

require "llm/providers/gemini/response_adapter/completion"
require "llm/providers/gemini/request_adapter/completion"

module LLM::Gemini::ResponseAdapter::Completion
  unless private_instance_methods(false).include?(:__original_adapt_choices_before_thought_sig)
    alias_method :__original_adapt_choices_before_thought_sig, :adapt_choices

    private

    def adapt_choices
      candidates.map.with_index do |choice, index|
        content = choice.content || LLM::Object.new
        role = content.role || "model"
        parts = content.parts || [ { "text" => choice.finishReason } ]
        text  = parts.filter_map { _1["text"] }.join

        # Keep the OUTER part (may contain thoughtSignature alongside
        # functionCall). tools (inner dicts) still populated for
        # adapt_tool_calls, which only reads name + args.
        tool_parts = parts.select { _1["functionCall"] }
        tools      = tool_parts.map { _1["functionCall"] }

        extra = {
          index:, response: self,
          tool_calls: adapt_tool_calls(tools),
          original_tool_calls: tools,        # kept for backward compat
          original_parts: tool_parts          # NEW: full parts w/ thoughtSignature
        }
        LLM::Message.new(role, text, extra)
      end
    end
  end
end

class LLM::Gemini::RequestAdapter::Completion
  unless instance_methods(false).include?(:__original_adapt_before_thought_sig)
    alias_method :__original_adapt_before_thought_sig, :adapt

    def adapt
      catch(:abort) do
        if Hash === message
          { role: message[:role], parts: adapt_content(message[:content]) }
        elsif message.tool_call?
          # Prefer original_parts (preserves thoughtSignature from thinking
          # Gemini models); fall back to reconstructing from
          # original_tool_calls for messages produced before this patch.
          parts = message.extra[:original_parts].presence ||
                  message.extra[:original_tool_calls].map { { "functionCall" => _1 } }
          { role: message.role, parts: parts }
        else
          { role: message.role, parts: adapt_content(message.content) }
        end
      end
    end
  end
end
