class LlmApiKey < ApplicationRecord
  belongs_to :user

  validates :uuid, uniqueness: true
  validates :llm_type, presence: true
  validates :description, length: { maximum: 255 }, allow_blank: true

  before_validation :set_uuid

  def encryptable_api_key
    EncryptableApiKey.new(encrypted_api_key: encrypted_api_key)
  end

  def encryptable_api_key=(encryptable_api_key)
    self.encrypted_api_key = encryptable_api_key.encrypted_api_key
  end

  private

  def set_uuid
    self.uuid ||= SecureRandom.uuid
  end
end
