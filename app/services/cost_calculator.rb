class CostCalculator
  PRICING_PATH = Rails.root.join("config", "model_pricing.yml")

  # Returns cost in integer cents for a single completion.
  # Unknown (llm_type, meta_id) returns 0 and logs a warning — fail-open
  # so a missing table entry doesn't break chat; missing entries surface
  # in the audit log when admins review usage.
  def self.compute(llm_type:, meta_id:, input_tokens:, output_tokens:)
    rates = pricing.dig(llm_type.to_s, meta_id.to_s)
    if rates.nil?
      Rails.logger.warn "[CostCalculator] no pricing for #{llm_type}/#{meta_id} — billing 0"
      return 0
    end

    input_usd  = (input_tokens.to_i  / 1_000_000.0) * rates.fetch("input").to_f
    output_usd = (output_tokens.to_i / 1_000_000.0) * rates.fetch("output").to_f

    ((input_usd + output_usd) * 100).round
  end

  def self.pricing
    @pricing ||= YAML.safe_load_file(PRICING_PATH)
  end

  # Test hook: force a re-read of the YAML (the spec stubs PRICING_PATH).
  def self.reset_pricing!
    @pricing = nil
  end
end
