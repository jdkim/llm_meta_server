# OpenAI Responses-API function-tool schemas.
#
# Stock llm.rb formats a function for /v1/responses with `strict: true` and
# `additionalProperties: false` (function.rb#format_openai). OpenAI's strict
# mode is not just a validation switch: it requires every key in `properties`
# to also appear in `required`, and rejects the whole request otherwise —
#
#   Invalid schema for function 'find_ids': 'required' is required to be
#   supplied and to be an array including every key in properties.
#
# MCP tool schemas routinely have optional parameters (PubDictionaries'
# `find_ids` takes a required `labels` and an optional `dictionary`), so
# strict mode would reject most of the tool set we broker. Chat completions
# sends the same schemas without `strict` and OpenAI accepts them, so match
# that here: a tool then behaves identically whichever endpoint the model
# happens to be routed to.
#
# Only the Responses branch is touched; chat completions already emits the
# lenient shape.
require "llm/function"
require "llm/providers/openai"

class LLM::Function
  alias_method :__original_format_openai_strict, :format_openai

  def format_openai(provider)
    return __original_format_openai_strict(provider) unless provider.class.to_s == "LLM::OpenAI::Responses"

    { type: "function", name: @name, description: @description, parameters: @params }.compact
  end
end
