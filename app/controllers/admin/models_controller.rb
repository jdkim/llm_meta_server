# frozen_string_literal: true

module Admin
  # Catalog management. The catalog lives in llm_models now, so edits here take
  # effect on the next request — no file edit, no deploy, no restart.
  class ModelsController < BaseController
    before_action :set_model, only: %i[edit update destroy toggle_active mark_reviewed apply_reference_price]

    def index
      @families = Llm.order(:family).includes(:llm_models)
      @validation = ModelCatalogValidator.validate
      @pricing_due = ModelPricingReview.due
      @checks = ModelCatalogCheck.latest_per_provider
      # Read from the last recorded check — rendering this page must never
      # depend on a third-party service being reachable.
      # api_ids the catalog already carries, so a stale check does not keep
      # advertising models that have since been added.
      @known_api_ids = LlmModelMap.catalog.values.flat_map { |ms| ms.values.map { |m| m[:api_id] } }.to_set
      @retired = @checks.flat_map { |c| c.retired_models.to_a }
      @price_check = ModelCatalogCheck.latest_pricing_drift
      @price_drift = @price_check&.new_in_provider.to_a
    end

    def new
      @model = LlmModel.new(llm: Llm.find_by(family: params[:provider]), name: params[:meta_id],
                            api_id: params[:api_id], display_name: params[:display_name],
                            supports_vision: true, supports_tools: true,
                            # Deliberately no price placeholder: a pre-filled 0.00
                            # reads as "already set" and would bill nothing.
                            pricing: { "reviewed_at" => Date.today.iso8601 })
      # Arriving from a discovered api_id: pre-fill using the same derivation
      # the scaffold task uses, so the operator only supplies the two prices.
      return if params[:api_id].blank?

      @model.name ||= ModelCatalogScaffold.meta_id_for(params[:api_id])
      # Prefer the provider's own name where it adds something the derived
      # one lacks — Google's "Nano Banana 2 Lite", for instance.
      @model.display_name ||= ModelCatalogScaffold.display_name_with_provider(params[:api_id], params[:display_name])

      # And the price, if a public reference has one — recorded as
      # `reference`, so it is visibly not the provider's own word.
      quote = begin
        PricingReference.for(params[:api_id])
      rescue PricingReference::FetchError
        nil
      end
      if quote
        @model.pricing = quote.to_pricing
        @model.released_on ||= quote.released_on
        # A per-image quote means an image generator. Without setting `kind`
        # too, the form arrives pre-filled with per_image pricing while still
        # classed as a chat model, and validation then demands input/output —
        # the entry cannot be saved as offered.
        if quote.image?
          @model.kind ||= "image"
          # An image generator does not do tool calling. The form defaults
          # both capability boxes on, which is right for a chat model and
          # wrong here — gemini-3.1-flash-lite-image was added advertising
          # tools its siblings correctly did not.
          @model.supports_tools = false
        end
      end
      @price_quote = quote
    end

    def create
      @model = LlmModel.new(model_params)
      # `position` carries the catalog's deliberate ordering, seeded from the
      # YAML. The column defaults to 0, so a model added here would tie with
      # the first entry and sort by id — appearing second in its provider
      # rather than last. Append instead.
      @model.position = next_position_for(@model.llm) if params.dig(:llm_model, :position).blank?
      if @model.save
        LlmModelMap.reload!
        redirect_to admin_models_path, notice: "Added #{@model.display_name}"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @model.update(model_params)
        LlmModelMap.reload!
        redirect_to admin_models_path, notice: "Updated #{@model.display_name}"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      name = @model.display_name
      @model.destroy!
      LlmModelMap.reload!
      redirect_to admin_models_path, notice: "Removed #{name}"
    end

    def toggle_active
      @model.update!(active: !@model.active?)
      LlmModelMap.reload!
      redirect_to admin_models_path,
                  notice: "#{@model.display_name} is now #{@model.active? ? 'available' : 'hidden'}"
    end

    def mark_reviewed
      changed = ModelPricingReview.mark_reviewed!(
        meta_id: @model.name, provider: @model.llm.family,
        input: params[:input], output: params[:output]
      )
      redirect_to admin_models_path, notice: "#{@model.display_name}: updated #{changed.join(', ')}"
    rescue ArgumentError
      redirect_to admin_models_path, alert: "Prices must be numbers"
    end

    # Runs the provider diff inline. A handful of HTTP calls, so it is a POST
    # the operator triggers rather than something the page does on render.
    def check_updates
      %w[openai anthropic google].each do |provider|
        resolved = ModelCheckKey.for(provider)
        unless resolved.present?
          ModelCatalogCheck.record!(provider: provider, error: "skipped: #{resolved.detail}")
          next
        end
        begin
          live = ProviderModelIndex.public_send(provider, resolved.key)
          catalog_ids = (LlmModelMap.catalog[provider] || {}).values.map { |m| m[:api_id] }
          diff = CatalogDiffer.diff(provider_models: live, catalog_api_ids: catalog_ids)
          missing = ProviderModelIndex.missing_from(catalog_ids, ProviderModelIndex.all_ids(provider, resolved.key))
          # Attach a reference price to each candidate so adding one is a
          # single click rather than a trip to the provider's pricing page.
          candidates = diff[:new_in_provider].map do |m|
            q = begin
              PricingReference.for(m[:id])
            rescue PricingReference::FetchError
              nil
            end
            { "api_id" => m[:id], "display_name" => m[:display_name] }.compact.merge(
              q ? { "input" => q.input, "output" => q.output, "sources" => q.sources } : {}
            )
          end

          ModelCatalogCheck.record!(provider: provider,
                                    new_in_provider: candidates,
                                    missing_from_provider: missing)
        rescue StandardError => e
          ModelCatalogCheck.record!(provider: provider, error: "#{e.class}: #{e.message}")
        end
      end
      redirect_to admin_models_path, notice: "Checked all providers"
    end

    # Re-fetches the public price references and re-compares.
    def check_prices
      rows = PricingReference.compare(refresh: true)
      ModelCatalogCheck.record_pricing_drift!(rows)
      # The reference is already loaded here, so fill in any missing release
      # dates while we have it.
      filled = PricingReference.backfill_release_dates!

      notice = rows.empty? ? "All prices match the public references" :
                             "#{rows.size} model(s) differ from the public references"
      notice += ". Filled in #{filled} release date(s)" if filled.positive?
      redirect_to admin_models_path, notice: notice
    rescue PricingReference::FetchError => e
      ModelCatalogCheck.record_pricing_drift!([], error: e.message)
      redirect_to admin_models_path, alert: "Price lookup failed: #{e.message}"
    end

    # Adopts the reference price for one model. Recorded as :reference, not
    # :verified — an aggregator is good evidence, not the provider's own word.
    def apply_reference_price
      quote = PricingReference.for(@model.api_id)
      return redirect_to(admin_models_path, alert: "No reference price for #{@model.api_id}") if quote.nil?

      @model.update!(pricing: @model.pricing.merge(quote.to_pricing))
      LlmModelMap.reload!
      # Re-record, or the drift panel keeps listing a row that is already
      # fixed — which reads as "the button did nothing".
      ModelCatalogCheck.record_pricing_drift!(PricingReference.compare)
      redirect_to admin_models_path,
                  notice: "#{@model.display_name}: set to #{quote.input}/#{quote.output} from #{quote.sources.join(' + ')}"
    end

    # Adopts the reference price for every model that currently differs.
    #
    # Prices that a human marked `verified` are deliberately left alone: they
    # were confirmed against the provider's own page, and a bulk action driven
    # by third-party aggregators should not quietly downgrade that. They are
    # reported instead, and can still be updated one at a time.
    def apply_all_reference_prices
      rows = PricingReference.compare(refresh: true)
      applied, skipped = [], []

      rows.each do |row|
        model = LlmModel.find_by(id: row[:id])
        next if model.nil?

        if model.pricing_provenance == :verified
          skipped << model.name
          next
        end

        quote = PricingReference.for(model.api_id)
        next if quote.nil?

        model.update!(pricing: model.pricing.merge(quote.to_pricing))
        applied << model.name
      end

      LlmModelMap.reload!
      ModelCatalogCheck.record_pricing_drift!(PricingReference.compare)

      notice = applied.empty? ? "No prices needed updating" : "Updated #{applied.size} price(s): #{applied.join(', ')}"
      notice += ". Left #{skipped.size} verified price(s) alone: #{skipped.join(', ')}" if skipped.any?
      redirect_to admin_models_path, notice: notice
    rescue PricingReference::FetchError => e
      redirect_to admin_models_path, alert: "Price lookup failed: #{e.message}"
    end

    # Resets the catalog to the checked-in config/llm_models.yml.
    def reseed
      stats = CatalogSeeder.call
      LlmModelMap.reload!
      redirect_to admin_models_path,
                  notice: "Reseeded from YAML — #{stats[:created]} added, #{stats[:updated]} updated"
    end

    private

    def set_model
      @model = LlmModel.find(params[:id])
    end

    def next_position_for(llm)
      return 0 if llm.nil?
      (llm.llm_models.maximum(:position) || -1) + 1
    end

    def model_params
      permitted = params.expect(llm_model: [ :llm_id, :name, :api_id, :display_name, :supports_vision,
                                             :supports_tools, :responses_only, :kind, :endpoint,
                                             :active, :notes, :position, :released_on, :defaults_json, :pricing_json ])
      defaults = parse_json(permitted.delete(:defaults_json))
      pricing  = parse_json(permitted.delete(:pricing_json))
      permitted.to_h.merge("defaults" => defaults, "pricing" => pricing).compact
    end

    def parse_json(raw)
      return nil if raw.nil?
      return {} if raw.strip.empty?
      JSON.parse(raw)
    rescue JSON::ParserError
      flash.now[:alert] = "defaults/pricing must be valid JSON — left unchanged"
      nil
    end
  end
end
