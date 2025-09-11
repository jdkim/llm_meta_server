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

  # Method to determine authentication provider
  def authentication_provider
    return :google_oauth2 if google_id.present?
    # Add conditions here when adding other IdPs in the future
    # return :azure_oauth2 if azure_id.present?
    # return :github if github_id.present?

    :unknown
  end

  # Check if user is a Google SSO user
  def google_sso_user?
    authentication_provider == :google_oauth2
  end

  # Check if user is an SSO (Single Sign-On) user
  def sso_user?
    authentication_provider != :unknown
  end
end
