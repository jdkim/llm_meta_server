# frozen_string_literal: true

# Aggregated stats for the hub super-user dashboard. Pure read-only;
# safe to call on every page render. Returned as a Hash so both the
# HTML view and the JSON API serialize from the same shape.
module AdminStats
  module_function

  def collect
    {
      generated_at: Time.current.iso8601,
      service: "hub",
      users: user_stats,
      llm_api_keys: api_key_stats,
      mcp: mcp_stats,
      favorites: favorites_stats,
      catalog: catalog_stats
    }
  end

  # Catalog health. Surfaces the two things that otherwise only appear when
  # someone remembers to run a rake task: pricing that has gone stale, and how
  # long it has been since the catalog was compared against each provider's
  # live model list.
  def catalog_stats
    validation = ModelCatalogValidator.validate
    due        = ModelPricingReview.due

    {
      models_by_provider: LlmModelMap.catalog.transform_values(&:size),
      models_total: LlmModelMap.catalog.values.sum(&:size),
      pricing_review_due: due.size,
      pricing_review_models: due.map { |r| "#{r[:llm_type]}/#{r[:meta_id]}" },
      validation_errors: validation[:errors].size,
      validation_warnings: validation[:warnings].size,
      provider_checks: ModelCatalogCheck.latest_per_provider.map { |c|
        {
          provider: c.provider,
          checked_at: c.checked_at.iso8601,
          days_ago: ((Time.current - c.checked_at) / 1.day).floor,
          new_in_provider: c.candidate_ids,
          missing_from_provider: c.missing_from_provider,
          error: c.error
        }
      }
    }
  end

  def user_stats
    {
      total: User.count,
      with_api_keys: User.joins(:llm_api_keys).distinct.count,
      with_default_model: User.where.not(default_model_meta_id: [ nil, "" ]).count,
      recent_signups_7d: User.where("created_at >= ?", 7.days.ago).count,
      recent: User.order(created_at: :desc).limit(5).pluck(:email, :created_at)
    }
  end

  def api_key_stats
    by_type = LlmApiKey.group(:llm_type).count
    {
      total: LlmApiKey.count,
      by_provider: by_type
    }
  end

  def mcp_stats
    servers = McpServer.all
    {
      servers_total: servers.count,
      servers_public: servers.where(public: true).count,
      servers_active: servers.where(active: true).count,
      tools_total: McpTool.count,
      tools_active: McpTool.where(active: true).count
    }
  end

  def favorites_stats
    top = User.where("favorite_model_meta_ids::text != '[]'")
              .pluck(:favorite_model_meta_ids)
              .flatten
              .tally
              .sort_by { |_, n| -n }
              .first(10)
              .to_h
    { top_favorited_models: top }
  end
end
