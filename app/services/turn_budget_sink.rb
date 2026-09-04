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

  attr_reader :deadline

  def initialize(sink, seconds:, clock: Time)
    @sink     = sink
    @seconds  = seconds
    @clock    = clock
    @deadline = clock.now + seconds
  end

  def <<(chunk)
    check!
    @sink << chunk
    self
  end

  # The Ollama stream parser calls this for thinking deltas when the sink
  # responds to it; budget applies equally, since thinking can run away too.
  def thinking(delta)
    check!
    @sink.thinking(delta) if @sink.respond_to?(:thinking)
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
