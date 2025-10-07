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

  def retrieve_key(uuid)
    llm_api_key = llm_api_keys.find_by(uuid: uuid)
    return nil unless llm_api_key

    EncryptableApiKey.new(encrypted_api_key: llm_api_key.encrypted_api_key).decrypt
  end
end
