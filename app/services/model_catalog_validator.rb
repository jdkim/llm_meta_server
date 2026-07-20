class ModelCatalogValidator
  ALLOWED_ENDPOINTS = %w[chat_completions responses].freeze
  ALLOWED_KINDS     = %w[image].freeze
  STALE_AFTER_DAYS  = 180 # ~6 months

  # A model is "chargeable" if the server bills the caller for its use.
  # Ollama runs locally (always $0). Image-gen models bill per-image, not
  # per-token — pricing is handled separately (or intentionally skipped).
  def self.chargeable?(llm_type, model)
    return false if llm_type == "ollama"
    return false if model[:kind].to_s == "image"
    true
  end

  # Runs all checks against LlmModelMap::MODEL_MAP.
  # Returns { errors: [strings], warnings: [strings] }.
  def self.validate(today: Date.today)
    errors   = []
    warnings = []

    LlmModelMap::MODEL_MAP.each do |llm_type, models|
      models.each do |meta_id, model|
        prefix = "#{llm_type}/#{meta_id}"

        errors << "#{prefix}: missing api_id"       if model[:api_id].to_s.empty?
        errors << "#{prefix}: missing display_name" if model[:display_name].to_s.empty?

        if model[:endpoint] && !ALLOWED_ENDPOINTS.include?(model[:endpoint].to_s)
          errors << "#{prefix}: endpoint=#{model[:endpoint].inspect} not in #{ALLOWED_ENDPOINTS.inspect}"
        end

        if model[:kind] && !ALLOWED_KINDS.include?(model[:kind].to_s)
          errors << "#{prefix}: kind=#{model[:kind].inspect} not in #{ALLOWED_KINDS.inspect}"
        end

        if chargeable?(llm_type, model)
          pricing = model[:pricing]
          if pricing.nil?
            errors << "#{prefix}: missing pricing block (chargeable model — required)"
          else
            errors << "#{prefix}: pricing.input missing"  unless pricing[:input].is_a?(Numeric)
            errors << "#{prefix}: pricing.output missing" unless pricing[:output].is_a?(Numeric)
            warnings.concat(reviewed_at_warnings(prefix, pricing[:reviewed_at], today))
          end
        elsif model[:pricing]
          warnings << "#{prefix}: has pricing block but is not chargeable (ollama or kind: image); pricing will be ignored"
        end
      end
    end

    { errors: errors, warnings: warnings }
  end

  def self.reviewed_at_warnings(prefix, reviewed_at, today)
    return [ "#{prefix}: pricing.reviewed_at missing — set it to today's date after verifying against the provider's pricing page" ] if reviewed_at.nil?

    date = reviewed_at.is_a?(Date) ? reviewed_at : begin
      Date.parse(reviewed_at.to_s)
    rescue ArgumentError
      return [ "#{prefix}: pricing.reviewed_at=#{reviewed_at.inspect} is not a valid date" ]
    end

    age = (today - date).to_i
    return [ "#{prefix}: pricing.reviewed_at is #{age} days old (stale after #{STALE_AFTER_DAYS}) — re-verify against the provider's pricing page" ] if age > STALE_AFTER_DAYS

    []
  end
end
