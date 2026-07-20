class CostCalculator
  # Returns cost in integer cents for a single completion.
  #
  # Pricing lives per-model in config/llm_models.yml under a `pricing:` block
  # (input/output USD per 1M tokens). Unknown (llm_type, meta_id) or a model
  # without a `pricing` block (e.g. Ollama, image-gen) returns 0 and logs a
  # warning — fail-open so a missing table entry doesn't break chat.
  def self.compute(llm_type:, meta_id:, input_tokens:, output_tokens:)
    rates = LlmModelMap::MODEL_MAP.dig(llm_type.to_s, meta_id.to_s, :pricing)
    if rates.nil?
      Rails.logger.warn "[CostCalculator] no pricing for #{llm_type}/#{meta_id} — billing 0"
      return 0
    end

    input_usd  = (input_tokens.to_i  / 1_000_000.0) * rates.fetch(:input).to_f
    output_usd = (output_tokens.to_i / 1_000_000.0) * rates.fetch(:output).to_f

    ((input_usd + output_usd) * 100).round
  end
end
