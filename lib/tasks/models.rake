namespace :models do
  PROVIDERS = %w[openai anthropic google].freeze

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

  desc "Diff config/llm_models.yml against each provider's live list-models endpoint. Uses stored provider keys; override with MODEL_CHECK_{OPENAI,ANTHROPIC,GOOGLE}_KEY. Optional: MODEL_CHECK_INCLUDE_DATED=1."
  task check_updates: :environment do
    include_dated = ENV["MODEL_CHECK_INCLUDE_DATED"].to_s == "1"

    PROVIDERS.each do |provider|
      puts "\n=== #{provider} ==="
      resolved = ModelCheckKey.for(provider)

      unless resolved.present?
        puts "  (skipped: #{resolved.detail})"
        ModelCatalogCheck.record!(provider: provider, error: "skipped: #{resolved.detail}")
        next
      end
      puts "  key: #{resolved.detail}"

      begin
        provider_models = ProviderModelIndex.public_send(provider, resolved.key, include_dated: include_dated)
      rescue ProviderModelIndex::FetchError, StandardError => e
        warn "  warning: fetch failed for #{provider} — #{e.class}: #{e.message}"
        ModelCatalogCheck.record!(provider: provider, error: "#{e.class}: #{e.message}")
        next
      end

      catalog_api_ids = (LlmModelMap::MODEL_MAP[provider] || {}).values.map { |m| m[:api_id] }
      diff = CatalogDiffer.diff(provider_models: provider_models, catalog_api_ids: catalog_api_ids)
      new_ids = diff[:new_in_provider].map { |m| m[:id] }

      # Retirement is checked against the UNFILTERED provider list — see
      # ProviderModelIndex.all_ids. The filtered list omits live models the
      # frontier/lookback heuristics skip, which made this report false alarms.
      truly_missing =
        begin
          live = ProviderModelIndex.all_ids(provider, resolved.key)
          ProviderModelIndex.missing_from(catalog_api_ids, live)
        rescue StandardError => e
          warn "  warning: retirement check skipped for #{provider} — #{e.class}: #{e.message}"
          []
        end
      diff = diff.merge(missing_from_provider: truly_missing)

      ModelCatalogCheck.record!(provider: provider,
                                new_in_provider: new_ids,
                                missing_from_provider: diff[:missing_from_provider])

      puts "  NEW candidates (in API, not in catalog):"
      if diff[:new_in_provider].empty?
        puts "    (none)"
      else
        diff[:new_in_provider].each do |m|
          created = m[:created_at] ? " (created #{m[:created_at]})" : ""
          puts "    - #{m[:id]}#{created}"
          puts "      add with: bin/rails models:scaffold API_ID=#{m[:id]} PROVIDER=#{provider}"
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

  desc "Print a paste-ready llm_models.yml entry. Env: API_ID (required), PROVIDER (required), VISION=0/1, TOOLS=0/1."
  task scaffold: :environment do
    api_id   = ENV["API_ID"].to_s
    provider = ENV["PROVIDER"].to_s

    if api_id.empty? || provider.empty?
      warn "usage: bin/rails models:scaffold API_ID=<provider-model-id> PROVIDER=<openai|anthropic|google>"
      exit 2
    end
    unless PROVIDERS.include?(provider)
      warn "PROVIDER must be one of #{PROVIDERS.join(', ')}"
      exit 2
    end

    vision = ENV.fetch("VISION", "1") == "1"
    tools  = ENV.fetch("TOOLS", "1") == "1"

    puts "# Paste under the `#{provider}:` key in config/llm_models.yml"
    puts ModelCatalogScaffold.entry_for(api_id, provider: provider, vision: vision, tools: tools)
  end

  desc "Compare catalog prices against the public references (LiteLLM, OpenRouter) and record the drift."
  task check_prices: :environment do
    rows = PricingReference.compare(refresh: true)
    ModelCatalogCheck.record_pricing_drift!(rows)

    if rows.empty?
      puts "models:check_prices — all prices match the public references"
    else
      puts "#{rows.size} model(s) differ from the public references:\n"
      rows.each do |r|
        agree = r[:agree] ? "both sources agree" : "sources: #{r[:sources].join(', ')}"
        puts format("  %-18s ours %s/%s   reference %s/%s   (%s)",
                    r[:meta_id], r[:ours_input], r[:ours_output], r[:ref_input], r[:ref_output], agree)
      end
      puts "\nAdopt them at /admin/models — nothing is changed automatically."
    end
  rescue PricingReference::FetchError => e
    ModelCatalogCheck.record_pricing_drift!([], error: e.message)
    warn "models:check_prices failed: #{e.message}"
  end

  desc "List models whose pricing needs review (missing or stale reviewed_at), with the provider pricing page."
  task review_pricing: :environment do
    rows = ModelPricingReview.due
    if rows.empty?
      puts "models:review_pricing — nothing due (all pricing reviewed within #{ModelCatalogValidator::STALE_AFTER_DAYS} days)"
      next
    end

    puts "#{rows.size} model(s) need a pricing review:\n\n"
    rows.each do |r|
      puts "  #{r[:llm_type]}/#{r[:meta_id]}  (#{r[:reason]})"
      puts "    current: input=#{r[:input]} output=#{r[:output]} reviewed_at=#{r[:reviewed_at] || '(none)'}"
      puts "    verify : #{r[:pricing_url]}"
      puts "    confirm: bin/rails models:mark_reviewed META_ID=#{r[:meta_id]} PROVIDER=#{r[:llm_type]} [INPUT=x OUTPUT=y]"
      puts
    end
  end

  desc "Record a pricing review: updates reviewed_at (and optionally input/output) in place. Env: META_ID, PROVIDER, INPUT, OUTPUT."
  task mark_reviewed: :environment do
    meta_id  = ENV["META_ID"].to_s
    provider = ENV["PROVIDER"].to_s

    if meta_id.empty? || provider.empty?
      warn "usage: bin/rails models:mark_reviewed META_ID=<meta_id> PROVIDER=<provider> [INPUT=<usd> OUTPUT=<usd>]"
      exit 2
    end

    changed = ModelPricingReview.mark_reviewed!(
      meta_id: meta_id, provider: provider,
      input: ENV["INPUT"], output: ENV["OUTPUT"]
    )
    puts "updated #{provider}/#{meta_id}: #{changed.join(', ')}"
    puts "run `bin/rails models:validate` and restart the server to pick it up"
  rescue ModelPricingReview::NotFound => e
    warn "error: #{e.message}"
    exit 1
  end
end
