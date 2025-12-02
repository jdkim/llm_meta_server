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

  def self.default_ollama_json
    {
      llm_type: "ollama",
      description: "[Ollama] Local Ollama (no API key required)",
      uuid: "ollama-local",
      available_models: LlmModelMap.available_models_for("ollama")
    }
  end
end
