class LlmApiKey < ApplicationRecord
  belongs_to :user

  validates :uuid, uniqueness: true
  validates :llm_type, presence: true
  validates :description, length: { maximum: 255 }, allow_blank: true

  attr_accessor :api_key

  before_validation :set_uuid, :encrypt_api_key

  def encryptable_api_key
    EncryptableApiKey.new(encrypted_api_key: encrypted_api_key)
  end

  private

  def set_uuid
    self.uuid ||= SecureRandom.uuid
  end

  def encrypt_api_key
    self.encrypted_api_key = ApiKeyEncrypter.new.encrypt(api_key) if api_key.present?
    self.api_key = nil
  end
end
