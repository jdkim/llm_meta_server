class LlmApiKey < ApplicationRecord
  belongs_to :user

  validates :uuid, presence: true, uniqueness: true
  validates :llm_type, presence: true
  validates :description, length: { maximum: 255 }, allow_blank: true

  attr_accessor :api_key

  before_save :set_uuid
  before_save :encrypt_api_key

  private

  def set_uuid
    self.uuid ||= SecureRandom.uuid
  end

  def encrypt_api_key
    self.encrypted_api_key = ApiKeyEncrypter.new.encrypt(api_key) unless api_key.blank?
    self.api_key = nil
  end
end
