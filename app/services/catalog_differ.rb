class CatalogDiffer
  # Pure function: given a provider's live model list and the catalog's api_ids
  # for that provider, return which are new (in provider, not in catalog) and
  # which appear stale (in catalog, not returned by provider — could mean
  # deprecated, renamed, or the model requires a different tier).
  #
  # @param provider_models  [Array<Hash>] output of ProviderModelIndex.*
  #                                        each hash has :id and :created_at
  # @param catalog_api_ids  [Array<String>] api_id values from LlmModelMap for this provider
  # @return [Hash] { new_in_provider: [{id:, created_at:}, ...],
  #                  missing_from_provider: ["api_id", ...] }
  def self.diff(provider_models:, catalog_api_ids:)
    provider_ids = provider_models.map { |m| m[:id] }.to_set
    catalog_set  = catalog_api_ids.map(&:to_s).to_set

    {
      new_in_provider: provider_models.reject { |m| catalog_set.include?(m[:id]) },
      missing_from_provider: (catalog_set - provider_ids).sort
    }
  end
end
