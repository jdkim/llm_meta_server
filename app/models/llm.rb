class Llm < ApplicationRecord
  has_many :llm_api_keys, dependent: :destroy
  has_many :llm_models, dependent: :destroy

  validates :name, presence: true, uniqueness: true

  def as_json
    {
      id: id,
      name: name,
      created_at: created_at,
      updated_at: updated_at,
      models: llm_models.map(&:as_json)
    }
  end

  class << self
    def all_services_with_ollama
      # Get all registered LLM services with their models
      registered_llms = Llm.includes(:llm_models).all.map(&:as_json)

      # Add Ollama as a special service (no API key required)
      ollama_service = default_ollama_json

      registered_llms << ollama_service
    end

    private

    def default_ollama_json
      {
        llm_type: "ollama",
        description: "[Ollama] Local Ollama (no API key required)",
        uuid: "ollama-local",
        available_models: LlmModelMap.available_models_for("ollama")
      }
    end
  end
end
