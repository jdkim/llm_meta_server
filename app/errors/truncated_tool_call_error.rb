# A tool call arrived with arguments that are not usable as a Hash.
#
# Anthropic streams tool inputs as `input_json_delta` fragments which the
# stream parser accumulates into a JSON string and parses back into a Hash at
# `content_block_stop`. When a turn ends before that event — hitting the
# output cap mid-tool-call is the usual way — the accumulated string is never
# parsed. llm.rb then does `runner.call(**arguments)` and Ruby raises
# "no implicit conversion of String into Hash", which names neither the tool
# nor the cause.
class TruncatedToolCallError < StandardError
  attr_reader :tool_name

  def initialize(tool_name)
    @tool_name = tool_name
    super("The model's call to #{tool_name} was cut off before its arguments " \
          "were complete, so it could not be run. This usually means the turn " \
          "hit the output limit mid-call — try a shorter prompt or fewer tools.")
  end
end
