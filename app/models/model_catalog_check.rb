# frozen_string_literal: true

# One row per provider per `models:check_updates` run.
#
# The check itself was already possible; what was missing was any record that
# it had happened. Persisting each run lets the admin dashboard answer "when
# was the catalog last compared against the providers, and what did it find"
# without anyone re-running it, and gives the weekly cron somewhere to leave
# its results.
class ModelCatalogCheck < ApplicationRecord
  validates :provider, presence: true
  validates :checked_at, presence: true

  # The three model providers, plus a pseudo-provider for the price-reference
  # comparison. Recording the price check here too keeps it durable and shared
  # between puma workers — the cache store is :memory_store, so a cached
  # comparison would differ per worker and be refetched by each.
  PROVIDERS   = %w[openai anthropic google].freeze
  PRICING_KEY = "pricing"

  scope :recent_first, -> { order(checked_at: :desc) }

  def self.record!(provider:, new_in_provider: [], missing_from_provider: [], error: nil)
    create!(provider: provider.to_s,
            checked_at: Time.current,
            new_in_provider: Array(new_in_provider),
            missing_from_provider: Array(missing_from_provider),
            error: error)
  end

  def self.latest_for(provider)
    where(provider: provider.to_s).recent_first.first
  end

  # Latest row per model provider, newest first — what the dashboard renders.
  # Excludes the pricing pseudo-provider, which has its own panel.
  def self.latest_per_provider
    where(provider: PROVIDERS).group_by(&:provider).values.map { |rows| rows.max_by(&:checked_at) }
      .sort_by { |r| r.checked_at }.reverse
  end

  # Price drift is stored as the check's payload so the admin page can render
  # it without touching the network.
  def self.record_pricing_drift!(rows, error: nil)
    record!(provider: PRICING_KEY, new_in_provider: rows.map(&:deep_stringify_keys), error: error)
  end

  def self.latest_pricing_drift
    where(provider: PRICING_KEY).recent_first.first
  end

  # Candidates are stored as {api_id, input, output, sources} where a
  # reference price was found, and as a bare id string otherwise (and for rows
  # recorded before prices were looked up). Normalise on read.
  def candidates
    new_in_provider.map { |c| c.is_a?(Hash) ? c : { "api_id" => c.to_s } }
  end

  def candidate_ids = candidates.map { |c| c["api_id"] }

  # Candidates that are still genuinely missing.
  #
  # The stored row is a snapshot from when the check ran, so a model added
  # since would otherwise keep appearing as "available but not in the
  # catalog" — which reads as though adding it had failed. Filtering against
  # the live catalog costs nothing and keeps the panel honest between checks.
  def pending_candidates(known_api_ids)
    candidates.reject { |c| known_api_ids.include?(c["api_id"]) }
  end

  # Catalog models the provider no longer serves, resolved to live records.
  #
  # Like `pending_candidates`, this filters against the current catalog: a
  # model hidden or deleted since the check ran should stop being reported,
  # otherwise the panel nags about work already done.
  def retired_models
    return LlmModel.none if missing_from_provider.blank?

    LlmModel.active.joins(:llm)
            .where(llms: { family: provider })
            .where(api_id: missing_from_provider)
  end

  def ok? = error.blank?
  def actionable? = ok? && (new_in_provider.any? || missing_from_provider.any?)
end
