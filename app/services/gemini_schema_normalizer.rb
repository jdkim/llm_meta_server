class GeminiSchemaNormalizer
  # Gemini's function-calling schema is a strict subset of JSON Schema
  # (Protocol-Buffer-backed). Three constructs are common in MCP tool
  # schemas and break Gemini's request validation:
  #
  #   1. `type: ["string", "null"]` (nullable via type array) →
  #      Gemini rejects "Proto field is not repeating, cannot start list".
  #      Rewrite as {type: "string", nullable: true}.
  #
  #   2. `uniqueItems: true` on array fields →
  #      Gemini: "Cannot find field." Strip; the constraint is dropped.
  #
  #   3. `additionalProperties: <bool>` on object schemas →
  #      Gemini: "Cannot find field." Strip; extras are implicitly allowed.
  #
  # Anthropic and OpenAI accept the full JSON Schema, so this normalizer runs
  # only for Gemini (gated at the LLM::Function#adapt patch in initializers).

  # Recursion boundary: we descend into these keys because they can contain
  # nested schema subtrees. Anything else is treated as a scalar leaf.
  NESTED_KEYS = %i[properties items oneOf anyOf allOf definitions].freeze

  class << self
    # Returns a NEW hash — never mutates the input. Deep-symbolizes keys on
    # the way down so callers who pass string-keyed schemas get a consistent
    # symbol-keyed result (matches llm.rb's expected shape).
    def normalize(schema)
      return schema unless schema.is_a?(Hash)
      walk(schema.deep_symbolize_keys)
    end

    private

    def walk(node)
      return node unless node.is_a?(Hash)

      out = {}
      node.each do |key, value|
        case key
        when :type
          out.merge!(normalize_type(value))
        when :uniqueItems, :additionalProperties
          # Drop — Gemini rejects both.
          next
        when :properties
          # Each property value is itself a schema — recurse into each.
          out[:properties] = value.is_a?(Hash) ? value.transform_values { walk(_1) } : value
        when :items
          # Array item schema — recurse.
          out[:items] = walk(value)
        when :oneOf, :anyOf, :allOf, :definitions
          out[key] = value.is_a?(Array) ? value.map { walk(_1) } : value
        else
          out[key] = value
        end
      end
      out
    end

    # `type` handling:
    #   "string"                → {type: "string"}                  (unchanged)
    #   ["string", "null"]      → {type: "string", nullable: true}  (nullable rewrite)
    #   ["null", "string"]      → {type: "string", nullable: true}  (order-independent)
    #   ["string", "number"]    → {type: "string"}                  (pick first non-null,
    #                                                                 drop the alternatives —
    #                                                                 Gemini has no union type)
    #   [] / [nil]              → {}                                (nothing to declare)
    def normalize_type(value)
      return { type: value } unless value.is_a?(Array)

      non_null = value.map(&:to_s).reject { |t| t == "null" }
      nullable = value.map(&:to_s).include?("null")

      return {} if non_null.empty?

      result = { type: non_null.first }
      result[:nullable] = true if nullable
      result
    end
  end
end
