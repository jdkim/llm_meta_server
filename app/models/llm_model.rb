# frozen_string_literal: true

# One entry in the model catalog. Since the catalog moved out of
# config/llm_models.yml (see AddCatalogFieldsToLlmModels), this is the single
# source of truth for which models the server exposes and how they behave.
#
# `name` is the meta_id: URL-safe, appears in routes and favourites.
# `api_id` is the provider's real id (with dots/colons).
class LlmModel < ApplicationRecord
  belongs_to :llm

  validates :name, presence: true,
            uniqueness: { scope: :llm_id,
                          message: "is already in the catalog for this provider — edit that entry instead of adding it again" }
  validates :api_id, presence: true
  validates :display_name, presence: true
  validate  :name_must_be_url_safe
  validate  :endpoint_must_be_known
  validate  :kind_must_be_known
  validate  :chargeable_models_must_be_priced

  # Users reference models by meta_id in their favourites and default-model
  # settings, and those are plain strings with no foreign key to enforce them.
  # Deleting a model therefore used to leave silent danglers: the favourite
  # stayed in the list, matched nothing, and simply stopped rendering — which
  # looks to the user like their model vanished from the picker for no reason.
  #
  # Hiding a model (active: false) deliberately does NOT purge: hiding is
  # reversible and the favourite should survive it. Only destruction does.
  after_destroy :purge_from_user_preferences

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :id) }

  # Catalog display order: chat models before image generators, then most
  # expensive first. This is what the YAML was hand-ordered to express
  # (flagship at the top, image models at the bottom); deriving it from price
  # keeps it true as models are added, instead of depending on someone
  # slotting each new row into the right place.
  #
  # Free models (Ollama) sort to the end of their group — they have no price
  # to rank by, and they are not the headline of a provider list.
  # Removes this model's meta_id from every user's favourites, and clears it
  # from anyone whose default it was. Returns the number of users touched.
  def purge_from_user_preferences
    touched = 0

    User.where(default_model_meta_id: name).find_each do |user|
      user.update_columns(default_model_meta_id: nil)
      touched += 1
    end

    User.find_each do |user|
      favourites = user.favorite_model_meta_ids
      next unless favourites.include?(name)

      # update! rather than update_columns: the column is JSON-serialized, so
      # it has to go through the attribute coder to be written correctly.
      user.update!(favorite_model_meta_ids: favourites - [ name ])
      touched += 1
    end

    touched
  end

  def self.catalog_order(models)
    models.sort_by { |m| [ m.image? ? 1 : 0, -m.sort_price, m.display_name.to_s.downcase ] }
  end

  # The figure this model is ranked by: per-image for generators, input cost
  # per 1M tokens for everything else.
  def sort_price
    p = pricing_symbolized
    (image? ? p[:per_image] : p[:input]).to_f
  end

  ALLOWED_ENDPOINTS = %w[chat_completions responses].freeze
  ALLOWED_KINDS     = %w[image].freeze

  def meta_id = name

  # Tools force the chat-completions path, so a Responses-only model cannot
  # use them here however capable the model itself is (see gpt-5.5-pro).
  def tool_capable? = supports_tools? && !responses_only?

  def image? = kind.to_s == "image"

  # Ollama runs locally and is always free; everything else bills the caller.
  def chargeable? = llm&.family.to_s != "ollama"

  # Where this price came from. Recorded because the catalog once carried
  # three prices a model had *extrapolated* — all under-charging by 3-6x —
  # documented only in a prose comment nobody read.
  #   :verified  a human confirmed it against the provider's own page
  #   :reference looked up from a public aggregator (LiteLLM / OpenRouter)
  #   :estimated guessed; must not be trusted
  #   :unknown   pre-dates provenance tracking
  def pricing_provenance
    p = pricing_symbolized
    return :verified  if p[:verified] == true
    return :reference if p[:source].present?
    return :estimated if notes.to_s.match?(/PROVISIONAL/i)
    :unknown
  end

  def pricing_trustworthy? = pricing_provenance == :verified

  # Kept ADDITIVE on purpose. /api/llms has served {name, display_name,
  # created_at, updated_at} to the client gem for a long time; the catalog
  # fields are added alongside rather than replacing them, so no consumer
  # breaks on the move to the database.
  def as_json(options = {})
    {
      name: name,
      display_name: display_name,
      created_at: created_at,
      updated_at: updated_at,
      api_id: api_id,
      supports_vision: supports_vision?,
      supports_tools: tool_capable?,
      kind: kind.to_s.presence,
      active: active?
    }
  end

  # Shape consumed by the model picker — mirrors what LlmModelMap built from
  # the YAML, so that frontend contract is unchanged too.
  def to_picker_json
    tier, label = LlmModelMap.pricing_tier_and_label(pricing_symbolized)
    {
      "label" => display_name,
      "value" => name,
      "supports_vision" => supports_vision?,
      "supports_tools" => tool_capable?,
      "kind" => kind.to_s.presence,
      "pricing_tier" => tier,
      "pricing_label" => label
    }
  end

  # The catalog hash shape LlmModelMap exposes (symbol keys, nested defaults).
  def to_catalog_entry
    {
      api_id: api_id,
      display_name: display_name,
      supports_vision: supports_vision?,
      supports_tools: supports_tools?,
      responses_only: responses_only?,
      kind: kind.presence&.to_sym,
      endpoint: endpoint.presence,
      released_on: released_on,
      # `.presence` so an empty jsonb column reads as absent, exactly as a
      # missing YAML key used to — CostCalculator distinguishes nil (unpriced,
      # e.g. Ollama) from a pricing hash and would KeyError on {}.
      defaults: defaults_symbolized.presence,
      pricing: pricing_symbolized.presence,
      notes: notes
    }.compact
  end

  def defaults_symbolized = (defaults.presence || {}).deep_symbolize_keys
  def pricing_symbolized  = (pricing.presence  || {}).deep_symbolize_keys

  private

  # A price of 0 is worse than a missing one: it looks filled in, satisfies a
  # "is it numeric?" check, and makes CostCalculator bill nothing at all — the
  # service would quietly give the model away. Require a real number instead.
  def chargeable_models_must_be_priced
    return unless chargeable?
    p = pricing_symbolized

    if image?
      errors.add(:pricing, "needs a positive per_image price") unless p[:per_image].to_f.positive?
    else
      errors.add(:pricing, "needs a positive input price")  unless p[:input].to_f.positive?
      errors.add(:pricing, "needs a positive output price") unless p[:output].to_f.positive?
    end
  end

  def name_must_be_url_safe
    return if name.blank? || name.match?(/\A[A-Za-z0-9_-]+\z/)
    errors.add(:name, "must be URL-safe (letters, digits, dash, underscore) — it appears in routes")
  end

  def endpoint_must_be_known
    return if endpoint.blank? || ALLOWED_ENDPOINTS.include?(endpoint.to_s)
    errors.add(:endpoint, "must be one of #{ALLOWED_ENDPOINTS.join(', ')}")
  end

  def kind_must_be_known
    return if kind.blank? || ALLOWED_KINDS.include?(kind.to_s)
    errors.add(:kind, "must be one of #{ALLOWED_KINDS.join(', ')}")
  end
end
