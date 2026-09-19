# frozen_string_literal: true

# Patch llm.rb's LLM::Message#functions to survive a tool call that names a
# tool which isn't on the request.
#
# Stock code (message.rb:72-76) is:
#
#   function = available_tools.find { _1.name.to_s == fn["name"] }.dup
#   function.tap { _1.id = fn.id }
#
# `find` returns nil whenever the model invents a name (or echoes one the
# caller didn't send), `nil.dup` is still nil, and `nil.id =` raises
# "undefined method 'id=' for nil". There is no guard, so a single bad name
# aborts the whole stream and the user loses the turn to an opaque
# NoMethodError with no indication of which tool was at fault. Local models
# hallucinate tool names often enough that this is routine, not an edge case
# — and it gets likelier the more tools are attached.
#
# Fix: substitute a stub function that returns the MCP-shaped
# {"isError" => true, "content" => [...]} payload the rest of the stack
# already understands. LlmRbFacade#emit_tool_errors_to_sink surfaces it to
# the user, and it is fed back to the model as that call's result, so the
# model can correct itself instead of the run dying.

require "llm/message"
require "llm/function"

class LLM::Message
  remove_method :functions if instance_methods(false).include?(:functions)

  # The ONLY override of this method. Two branches used to each redefine it —
  # this file for hallucinated tool names, config/initializers/llm_session.rb
  # (from the client-orchestrated `develop` work) for replayed history — and
  # since initializers load alphabetically this one ran second and began with
  # `remove_method`, silently discarding the other. Both cases are real and
  # look identical from inside `find` ("no tool by that name"), so they are
  # told apart by where the message came from:
  #
  #   * known tool                      -> the registered function, pending
  #   * no provider response (replayed) -> rebuilt from the call, already called
  #   * live response, unknown name     -> an error stub the model can read
  def functions
    @functions ||= tool_calls.map do |fn|
      known = available_tools.find { _1.name.to_s == fn["name"].to_s }
      if known
        resolved_function(known, fn)
      elsif replayed?
        replayed_function(fn)
      else
        unknown_tool_function(fn)
      end
    end
  end

  private

  # A message rebuilt from client-sent history (LlmRbFacade
  # #messages_to_llm_objects, used by the client-orchestrated single_llm_calls
  # flow) carries tool_calls but no provider response, so available_tools is
  # always empty. Every call on it would otherwise look hallucinated.
  def replayed?
    response.nil?
  end

  # The client already dispatched this call, so it is marked called:
  # Session#functions selects only pending ones and must not re-run it.
  def replayed_function(fn)
    LLM::Function.new(fn["name"].to_s).tap do |f|
      f.id = fn["id"] || fn.id
      f.arguments = fn["arguments"] || fn.arguments
      f.instance_variable_set(:@called, true)
    end
  end

  def resolved_function(tool, fn)
    tool.dup.tap do |f|
      f.id = fn.id
      f.arguments = fn.arguments
    end
  end

  # The stub must never raise when called. LLM::Function#call splats the
  # arguments (`runner.call(**arguments)`), and a hallucinated call can carry
  # nil or a non-Hash, so we pin them to {} rather than pass them through —
  # the arguments to a nonexistent tool carry no information we need. The
  # user still sees what the model actually attempted: the "Tool calls"
  # section reads arguments from Session#extract_tool_calls (the message
  # buffer), not from this object.
  def unknown_tool_function(fn)
    requested = fn["name"].to_s
    offered   = available_tools.map { _1.name.to_s }.sort

    LLM::Function.new(requested) { |f|
      f.description "Unavailable tool referenced by the model"
      f.define ->(**) {
        {
          "isError" => true,
          "content" => [ {
            "type" => "text",
            "text" => "No tool named #{requested.inspect} is available. " \
                      "Available tools: #{offered.join(', ')}. " \
                      "Call one of those, or answer without calling a tool."
          } ]
        }
      }
    }.tap do |f|
      f.id = fn.id
      f.arguments = {}
    end
  end
end
