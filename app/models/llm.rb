class Llm < ApplicationRecord
  # NOTE: no has_many :llm_api_keys — llm_api_keys is keyed by the `llm_type`
  # string, not an llm_id foreign key, so the association could never load.
  # It raised PG::UndefinedColumn the first time anything destroyed an Llm.
  has_many :llm_models, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :family, presence: true, uniqueness: true

  def as_json(options = {})
    {
      id: id,
      name: name,
      family: family,
      created_at: created_at,
      updated_at: updated_at,
      # Same order the catalog and picker use — chat models before image
      # generators, most expensive first. Consumers of /api/llms (the chat
      # app renders these as the "locked" provider cards for visitors with no
      # API key) would otherwise show them in raw row order.
      models: LlmModel.catalog_order(llm_models.select(&:active?)).map(&:as_json)
    }
  end

  class << self
    def all_services_with_ollama(user: nil)
      # Get all registered LLM services except Ollama (handled separately below)
      registered_llms = Llm.includes(:llm_models).where.not(family: "ollama").map(&:as_json)

      # Add Ollama as a special service (no API key required)
      registered_llms << default_ollama_json(user: user)
    end

    private

    def default_ollama_json(user: nil)
      favorited    = user&.favorite_model_meta_ids || []
      default_meta = user&.default_model_meta_id
      models = LlmModelMap.available_models_for("ollama").map do |m|
        m.merge(
          "favorite" => favorited.include?(m["value"]),
          "default"  => default_meta.present? && default_meta == m["value"]
        )
      end

      {
        family: "ollama",
        description: "[Ollama] Local Ollama (no API key required)",
        uuid: "ollama-local",
        available_models: models
      }
    end
  end
end
