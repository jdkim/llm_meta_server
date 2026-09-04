# OpenAI Responses-API conversation history.
#
# Stock llm.rb labels every String message content as `input_text`
# (request_adapter/respond.rb#adapt_content), whatever the role. That is right
# for user turns and wrong for assistant ones: the Responses API rejects an
# assistant item carrying `input_text`, which needs `output_text`. The effect
# was that no request with history could use Responses at all, so LlmRbFacade
# routed every multi-turn request to chat completions — losing reasoning
# summaries after the first message, and making `responses_only` models
# (gpt-5.5-pro) unusable beyond turn one.
#
# This patch reads the role the adapter already holds and labels assistant
# text `output_text`. Everything else — user text, images, files, function
# call output — falls through to the original implementation untouched.
require "llm/providers/openai"

class LLM::OpenAI::RequestAdapter::Respond
  private

  alias_method :__original_adapt_content_for_history, :adapt_content

  def adapt_content(content)
    if String === content && __assistant_message?
      [ { type: :output_text, text: content.to_s } ]
    else
      __original_adapt_content_for_history(content)
    end
  end

  # `adapt` accepts both LLM::Message objects and plain role/content hashes;
  # read the role from whichever shape arrived.
  def __assistant_message?
    role = if Hash === @message
             @message[:role] || @message["role"]
    elsif @message.respond_to?(:role)
             @message.role
    end
    role.to_s == "assistant"
  end
end
