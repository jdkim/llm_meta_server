class User < ApplicationRecord
  # Lifetime trial budget granted automatically when a new user signs up.
  # Off by default; set SIGNUP_GRANT_CENTS in the environment (e.g. 3000
  # for $30) to enable the auto-grant. Any value <= 0 is a no-op.
  SIGNUP_GRANT_CENTS = ENV.fetch("SIGNUP_GRANT_CENTS", "0").to_i

  devise :omniauthable, omniauth_providers: %i[google_oauth2]

  has_many :llm_api_keys, dependent: :destroy
  has_many :mcp_servers, dependent: :destroy
  has_many :credit_transactions, dependent: :destroy

  after_create :grant_signup_credit

  # Per-user list of favorited model meta_ids (globally unique strings like
  # "gpt-5", "claude-opus-4-7", "qwen3-6-35b-fast"). Stored as a JSON array of strings.
  # The attribute-level default guarantees [] at write time even when a new
  # record is built without setting the attribute (e.g. via Devise omniauth's
  # block-only initializer, which would otherwise hit the NOT NULL constraint).
  serialize :favorite_model_meta_ids, coder: JSON
  attribute :favorite_model_meta_ids, default: -> { [] }

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

  def favorite_model?(meta_id)
    favorite_model_meta_ids.include?(meta_id.to_s)
  end

  # Sum of all credit transactions — grants positive, usages negative.
  # Used by the shared-key fallback to decide whether the user has trial
  # budget remaining.
  def current_balance_cents
    credit_transactions.sum(:amount_cents)
  end

  # True if this user's email is listed in the SUPER_USER_EMAILS env
  # (comma-separated). Cheap config-driven authorization — no DB
  # column, no admin UI required to add/remove super users; just edit
  # the env file and restart.
  def super_user?
    self.class.super_user_emails.include?(email.to_s.downcase)
  end

  def self.super_user_emails
    ENV.fetch("SUPER_USER_EMAILS", "").split(",").map { |e| e.strip.downcase }.reject(&:empty?)
  end

  # Add/remove the meta_id from the favorites list. Returns the resulting
  # boolean (true if now favorited).
  def toggle_favorite_model!(meta_id)
    list = favorite_model_meta_ids.dup
    if list.include?(meta_id.to_s)
      list.delete(meta_id.to_s)
      result = false
    else
      list << meta_id.to_s
      result = true
    end
    update!(favorite_model_meta_ids: list)
    result
  end

  private

  def grant_signup_credit
    return if SIGNUP_GRANT_CENTS <= 0
    credit_transactions.create!(
      kind: "signup_grant",
      amount_cents: SIGNUP_GRANT_CENTS,
      note: "auto-grant on signup"
    )
  end
end
