# Patch llm.rb's Anthropic provider so that tool-result messages get
# appended to the session's history with role: :user (Anthropic's protocol)
# instead of :tool (llm.rb's default from LLM::Provider#tool_role).
#
# Symptom without this patch: multi-turn tool loops on Anthropic fail on the
# second iteration with
#   invalid_request_error: messages: Unexpected role "tool".
#   Allowed roles are "user" or "assistant".
# because iteration 1's appended tool-results message (role: "tool") rides
# along in iteration 2's outgoing messages: array. The API accepts it inline
# in iteration 1 only because the OUTGOING prompt uses Anthropic's default
# :user role — the persisted role in the session buffer is what poisons the
# next turn.
#
# The `tool_role` method is only consumed by LLM::Bot#talk / #respond, and
# only to tag the message that carries tool_result content — so returning
# :user for Anthropic is the correct protocol shape (Anthropic wraps tool
# results as user messages with content: [{type: "tool_result", ...}]).

require "llm/providers/anthropic"

class LLM::Anthropic
  # Only redefine if the provider hasn't already overridden it — future
  # llm.rb versions may ship the fix upstream, at which point this becomes
  # a no-op.
  unless instance_methods(false).include?(:tool_role)
    def tool_role
      :user
    end
  end
end
