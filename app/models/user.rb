class User < ApplicationRecord
  devise :omniauthable, omniauth_providers: %i[google_oauth2]

  has_many :llm_api_keys, dependent: :destroy

  validates :email, presence: true, uniqueness: true
  validates :google_id, presence: true, uniqueness: true

  def self.from_omniauth(auth)
    where(email: auth.info.email).first_or_create do |user|
      user.email = auth.info.email
      user.google_id = auth.uid
    end
  end

  def find_llm_api_key(uuid)
    # If there is no llm_api_key corresponding to the uuid, return nil and use Ollama
    llm_api_keys.find_by(uuid: uuid)
  end

  def key_for(uuid)
    llm_api_key = llm_api_keys.find_by(uuid: uuid)
    return nil unless llm_api_key

    llm_api_key.encryptable_api_key
  end

  def llm_api_keys_with_ollama
    llm_api_keys.map(&:as_json) << default_ollama_json
  end

  def default_ollama_json
    {
      llm_type: "ollama",
      description: "[Ollama] Local Ollama (no API key required)",
      uuid: "ollama-local",
      available_models: LlmModelMap.available_models_for("ollama")
    }
  end
end
