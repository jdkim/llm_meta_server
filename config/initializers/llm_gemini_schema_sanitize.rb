# Patch llm.rb's LLM::Function#adapt so that when serializing for Gemini,
# the tool's JSON Schema goes through GeminiSchemaNormalizer first.
#
# Symptom without this patch: any MCP server whose tool schemas use
# `type: ["string", "null"]` (nullable), `uniqueItems`, or
# `additionalProperties` fails Gemini's request validation with
#   400 INVALID_ARGUMENT: Invalid JSON payload received.
#   Unknown name "type"/"uniqueItems"/"additionalProperties" ...
# because Gemini's function-calling schema is a strict subset of JSON Schema
# (Protocol-Buffer-backed).
#
# Anthropic and OpenAI accept the full JSON Schema; we scope the normalization
# to Gemini only.

require "llm/function"
require Rails.root.join("app/services/gemini_schema_normalizer")

class LLM::Function
  unless instance_methods(false).include?(:__original_adapt_before_gemini_sanitize)
    alias_method :__original_adapt_before_gemini_sanitize, :adapt

    def adapt(provider)
      result = __original_adapt_before_gemini_sanitize(provider)
      if provider.class.to_s == "LLM::Gemini" && result.is_a?(Hash) && result[:parameters]
        result[:parameters] = GeminiSchemaNormalizer.normalize(result[:parameters])
      end
      result
    end
  end
end
