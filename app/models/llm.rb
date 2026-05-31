class Llm < ApplicationRecord
  has_many :llm_api_keys, dependent: :destroy
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
      models: llm_models.map(&:as_json)
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
