class LlmModelMap
  # Catalog source of truth: the llm_models table (see CatalogSeeder and
  # AddCatalogFieldsToLlmModels). It used to be config/llm_models.yml loaded
  # into a frozen constant at boot, which meant every change needed a deploy
  # and a restart — and made the catalog unmanageable from the admin UI. The
  # YAML remains as the checked-in seed / reset point, not as runtime state.
  #
  # `catalog` is memoized against the table's max(updated_at) so a normal
  # request does one cheap query instead of rebuilding, while an edit made in
  # another puma worker is still picked up without a restart.
  CATALOG_PATH = Rails.root.join("config", "llm_models.yml")

  class << self
    def catalog
      stamp = catalog_stamp
      if @catalog.nil? || @catalog_stamp != stamp
        @catalog       = build_catalog
        @catalog_stamp = stamp
      end
      @catalog
    end

    # Forces the next read to rebuild. Called after a catalog edit.
    def reload!
      @catalog = nil
      @catalog_stamp = nil
    end

    private

    def catalog_stamp
      [ LlmModel.maximum(:updated_at), LlmModel.count ]
    end

    def build_catalog
      LlmModel.active.includes(:llm).group_by { |m| m.llm.family }
              .transform_values { |models| LlmModel.catalog_order(models).to_h { |m| [ m.name, m.to_catalog_entry ] } }
              .freeze
    end
  end

  def self.fetch!(meta_id, llm_type: nil)
    model_data = catalog.dig(llm_type || "ollama", meta_id)
    raise ModelNotFoundError, meta_id if model_data.nil?
    model_data[:api_id]
  end

  # Per-model generation-parameter defaults from the catalog. Returns an
  # empty hash when none are declared. Callers merge these UNDER user-
  # supplied params (so a per-request value wins).
  def self.defaults_for(meta_id, llm_type: nil)
    catalog.dig(llm_type || "ollama", meta_id, :defaults) || {}
  end

  # Which HTTP endpoint the provider should use for this model.
  # Returns "chat_completions" by default; "responses" routes the OpenAI
  # streaming path through llm.responses.create (so reasoning summaries
  # can stream — they're hidden behind the chat completions endpoint).
  def self.endpoint_for(meta_id, llm_type: nil)
    catalog.dig(llm_type || "ollama", meta_id, :endpoint).to_s.presence || "chat_completions"
  end

  def self.available_models_for(llm_type)
    catalog.fetch(llm_type).map do |key, value|
      tier, label = pricing_tier_and_label(value[:pricing])
      {
        "label" => value[:display_name], # Display name: official model name
        "value" => key,                   # Internal ID: meta_id (without dots)
        "supports_vision" => value[:supports_vision] == true,
        "supports_tools" => tool_capable?(value),
        # `kind` is only emitted for image-gen models — the frontend
        # treats its absence as "regular chat model".
        "kind" => value[:kind].to_s.presence,
        # Pricing hints for the model picker chip. Nil for free (Ollama)
        # and image-gen (per-image billing, not per-token) — the frontend
        # renders no chip when these are absent.
        "pricing_tier" => tier,
        "pricing_label" => label
      }.compact
    end
  end

  # Bucketed by output rate for per-token models, per-image rate for image-gen.
  # Two-orders-of-magnitude gap between the two — hence separate thresholds.
  #
  # Per-token (output rate — usually dominates for chat):
  #   $   ≤ $3/M output      (cheap — mini/lite/haiku)
  #   $$  ≤ $15/M output     (mid — most flagships)
  #   $$$ >  $15/M output    (premium — Opus/Fable/Pro tiers)
  #
  # Per-image (typical single-image cost):
  #   $   ≤ $0.05/image      (cheap — flash-image tier)
  #   $$  ≤ $0.10/image      (mid — newer flash-image)
  #   $$$ >  $0.10/image     (premium — pro-image tier)
  def self.pricing_tier_and_label(pricing)
    return [ nil, nil ] unless pricing.is_a?(Hash)

    if pricing[:per_image]
      tier = case pricing[:per_image].to_f
      when ..0.05  then "$"
      when ..0.10  then "$$"
      else              "$$$"
      end
      [ tier, "$#{pricing[:per_image]} per image" ]
    elsif pricing[:input] && pricing[:output]
      tier = case pricing[:output].to_f
      when ..3.0   then "$"
      when ..15.0  then "$$"
      else              "$$$"
      end
      [ tier, "$#{pricing[:input]} / $#{pricing[:output]} per 1M tokens" ]
    else
      [ nil, nil ]
    end
  end

  def self.ollama_model?(model_id)
    catalog.fetch("ollama", {}).each_value.any? { |m| m[:api_id] == model_id }
  end

  def self.image_model?(meta_id, llm_type: nil)
    catalog.dig(llm_type || "ollama", meta_id, :kind).to_s == "image"
  end

  def self.supports_vision?(meta_id, llm_type: nil)
    catalog.dig(llm_type || "ollama", meta_id, :supports_vision) == true
  end

  def self.supports_tools?(meta_id, llm_type: nil)
    tool_capable?(catalog.dig(llm_type || "ollama", meta_id))
  end

  # Whether tools can actually be used with this model *through this server*,
  # as opposed to whether the model supports tool calling at all.
  #
  # Attaching tools forces the chat-completions path (LlmRbFacade#stream!
  # only takes the Responses branch when no tools, images or history are
  # present). A model flagged `responses_only` does not exist on chat
  # completions, so that combination always 400s — report it as tool-less so
  # the picker never offers it.
  def self.tool_capable?(model)
    return false unless model.is_a?(Hash)
    model[:supports_tools] == true && model[:responses_only] != true
  end
end
