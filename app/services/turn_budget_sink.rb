# frozen_string_literal: true

# Wraps the SSE sink with a wall-clock budget for one turn.
#
# Added after a production incident (2026-09-03): qwen3.6:35b-fast made a
# single tool call and then produced 87,961 characters over 10m51s, repeating
# "**Tool Calls:**" 420 times — a degenerate repetition inside ONE generation.
#
# Nothing caught it. The tool-iteration cap never applied (one iteration ran),
# and PROVIDER_READ_TIMEOUT_SECONDS never fired because tokens kept arriving,
# so the stream looked healthy the whole time. The user saw a hang.
#
# The check therefore has to live where the bytes arrive, not between loop
# iterations: raising from `<<` aborts mid-generation, which is the only place
# a runaway can be stopped.
class TurnBudgetSink
  class Exceeded < StandardError; end

  attr_reader :deadline, :content_bytes, :thinking_deltas, :thinking_bytes

  def initialize(sink, seconds:, clock: Time)
    @sink     = sink
    @seconds  = seconds
    @clock    = clock
    @deadline = clock.now + seconds
    # Counted here because this wrapper sees every byte of every stream,
    # whichever provider and whichever branch produced it. Without it there is
    # no record of whether a model emitted reasoning at all: a turn that
    # streamed no summary and a turn whose summary was lost downstream look
    # identical in the log, which cost a lot of guesswork on 2026-09-04.
    @content_bytes   = 0
    @thinking_deltas = 0
    @thinking_bytes  = 0
  end

  def <<(chunk)
    check!
    @content_bytes += chunk.to_s.bytesize
    @sink << chunk
    self
  end

  # The Ollama stream parser calls this for thinking deltas when the sink
  # responds to it; budget applies equally, since thinking can run away too.
  def thinking(delta)
    check!
    @thinking_deltas += 1
    @thinking_bytes  += delta.to_s.bytesize
    @sink.thinking(delta) if @sink.respond_to?(:thinking)
  end

  # One-line summary of what this turn actually streamed.
  def stream_stats
    "content=#{content_bytes}B reasoning=#{thinking_deltas}deltas/#{thinking_bytes}B"
  end

  def respond_to_missing?(name, include_private = false)
    @sink.respond_to?(name, include_private) || super
  end

  def method_missing(name, ...)
    @sink.respond_to?(name) ? @sink.public_send(name, ...) : super
  end

  private

  def check!
    return if @clock.now < @deadline

    raise Exceeded, "response exceeded the #{@seconds}s budget for a single turn"
  end
end
