# Patch llm.rb's EventStream::Parser#each_line to NOT yield partial lines.
#
# Bug in llm.rb 4.3.1 (lib/llm/eventstream/parser.rb): when a TCP chunk
# arrives mid-event (no trailing newline), each_line still yields the
# incomplete bytes as if they were a complete SSE line, then clears the
# buffer. The next chunk arrives as a separate "line". This breaks
# event-stream parsing whenever TCP splits an event across two reads —
# observable as silently dropped tokens in OpenAI streaming responses
# (e.g. asking for the alphabet returns ", B,, D,, F, G, H,..." with
# letters missing wherever a TCP boundary fell mid-event).
#
# Fix: drop the "yield remaining incomplete bytes" branch so partial
# lines stay in the buffer until the next chunk completes them.

require "llm/eventstream/parser"

class LLM::EventStream::Parser
  remove_method :each_line if private_instance_methods(false).include?(:each_line)

  private

  def each_line
    while (newline = @buffer.index("\n", @cursor))
      line = @buffer[@cursor..newline]
      @cursor = newline + 1
      yield(line)
    end
    return if @cursor.zero?
    @buffer = @buffer[@cursor..] || +""
    @cursor = 0
  end
end
