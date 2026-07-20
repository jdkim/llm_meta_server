namespace :models do
  desc "Validate config/llm_models.yml (required fields, pricing, staleness). Exits 1 on error."
  task validate: :environment do
    result = ModelCatalogValidator.validate

    result[:warnings].each { |w| warn "warning: #{w}" }
    result[:errors].each   { |e| warn "error:   #{e}" }

    if result[:errors].any?
      warn "\nmodels:validate FAILED — #{result[:errors].size} error(s), #{result[:warnings].size} warning(s)"
      exit 1
    end

    puts "models:validate OK — #{result[:warnings].size} warning(s)"
  end

  desc "Diff config/llm_models.yml against each provider's live list-models endpoint. Env: MODEL_CHECK_{OPENAI,ANTHROPIC,GOOGLE}_KEY. Optional: MODEL_CHECK_INCLUDE_DATED=1 to also show dated snapshot IDs."
  task check_updates: :environment do
    providers = {
      "openai"    => ENV["MODEL_CHECK_OPENAI_KEY"],
      "anthropic" => ENV["MODEL_CHECK_ANTHROPIC_KEY"],
      "google"    => ENV["MODEL_CHECK_GOOGLE_KEY"]
    }

    include_dated = ENV["MODEL_CHECK_INCLUDE_DATED"].to_s == "1"

    providers.each do |provider, key|
      puts "\n=== #{provider} ==="
      if key.to_s.empty?
        puts "  (skipped: MODEL_CHECK_#{provider.upcase}_KEY not set)"
        next
      end

      begin
        provider_models = ProviderModelIndex.public_send(provider, key, include_dated: include_dated)
      rescue ProviderModelIndex::FetchError, StandardError => e
        warn "  warning: fetch failed for #{provider} — #{e.class}: #{e.message}"
        next
      end

      catalog_api_ids = (LlmModelMap::MODEL_MAP[provider] || {}).values.map { |m| m[:api_id] }
      diff = CatalogDiffer.diff(provider_models: provider_models, catalog_api_ids: catalog_api_ids)

      puts "  NEW candidates (in API, not in catalog):"
      if diff[:new_in_provider].empty?
        puts "    (none)"
      else
        diff[:new_in_provider].each do |m|
          created = m[:created_at] ? " (created #{m[:created_at]})" : ""
          puts "    - #{m[:id]}#{created}"
        end
      end

      puts "  MISSING from API (in catalog, not returned):"
      if diff[:missing_from_provider].empty?
        puts "    (none)"
      else
        diff[:missing_from_provider].each { |id| puts "    - #{id}" }
      end
    end
  end
end
