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
end
