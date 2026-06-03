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
      favorites: favorites_stats
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
