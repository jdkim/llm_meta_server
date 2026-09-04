# frozen_string_literal: true

# Supports the routine "is our pricing still right?" pass.
#
# No provider publishes pricing over an API, so this stays a human step; the
# job here is to make it structured — list exactly what is due, point at the
# page to check, and record the outcome.
#
# Now that the catalog lives in the database, a review is a plain record
# update. (This previously rewrote config/llm_models.yml line by line to avoid
# a YAML round-trip deleting the file's comments; those comments are the
# `notes` column now, so that whole hazard is gone.)
class ModelPricingReview
  class NotFound < StandardError; end

  def self.due(today: Date.today)
    LlmModel.active.includes(:llm).filter_map do |model|
      family = model.llm.family
      next unless ModelCatalogValidator.chargeable?(family, model.to_catalog_entry)

      pricing  = model.pricing_symbolized
      reviewed = parse_date(pricing[:reviewed_at])
      reason =
        if reviewed.nil? then "no reviewed_at"
        elsif (today - reviewed).to_i > ModelCatalogValidator::STALE_AFTER_DAYS
          "reviewed #{(today - reviewed).to_i} days ago"
        end
      next unless reason

      {
        id: model.id, llm_type: family, meta_id: model.name, reason: reason,
        input: pricing[:input], output: pricing[:output],
        reviewed_at: pricing[:reviewed_at],
        pricing_url: ModelCatalogScaffold::PRICING_URLS[family] || "(provider pricing page)"
      }
    end.sort_by { |r| [ r[:llm_type], r[:meta_id] ] }
  end

  # Records a review. Returns the list of fields changed.
  def self.mark_reviewed!(meta_id:, provider:, input: nil, output: nil, today: Date.today)
    model = LlmModel.joins(:llm).find_by(llms: { family: provider.to_s }, name: meta_id.to_s)
    raise NotFound, "#{provider}/#{meta_id} not found in the catalog" if model.nil?

    pricing = model.pricing.presence || {}
    changed = []
    if input.present?
      pricing["input"] = Float(input)
      changed << "input"
    end
    if output.present?
      pricing["output"] = Float(output)
      changed << "output"
    end
    pricing["reviewed_at"] = today.iso8601
    changed << "reviewed_at"

    model.update!(pricing: pricing)
    LlmModelMap.reload!
    changed
  end

  def self.parse_date(value)
    return value if value.is_a?(Date)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
