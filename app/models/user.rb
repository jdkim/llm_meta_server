class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :omniauthable, omniauth_providers: %i[google_oauth2]

  # has_many :llm_api_keys, dependent: :destroy

  validates :email, presence: true, uniqueness: true
end
