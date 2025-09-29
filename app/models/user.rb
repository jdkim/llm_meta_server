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

  # Add API key
  def add_llm_apikey(llm_type, api_key, description)
    # Encrypt and save new API key
    encrypted_key = ApiKeyEncrypter.new.encrypt(api_key)

    llm_api_keys.create!(
      uuid: SecureRandom.uuid,
      llm_type: llm_type,
      encrypted_api_key: encrypted_key,
      description: description
    )
  end
end
