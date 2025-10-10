class LlmApiKey < ApplicationRecord
  belongs_to :user

  validates :uuid, uniqueness: true
  validates :llm_type, presence: true
  validates :description, length: { maximum: 255 }, allow_blank: true

  before_validation :set_uuid
  before_validation :initialize_encryptable_api_key

  LLM_SERVICES = {
    "ollama" => :ollama,
    "openai" => :openai,
    "anthropic" => :anthropic,
    "google" => :gemini
  }.freeze

  def encryptable_api_key
    @encryptable_api_key ||= EncryptableApiKey.new(encrypted_api_key: encrypted_api_key)
  end

  def encryptable_api_key=(encryptable_api_key)
    raise ArgumentError, "encryptable_api_key cannot be nil" if encryptable_api_key.nil?

    @encryptable_api_key = encryptable_api_key
    self.encrypted_api_key = encryptable_api_key.encrypted_api_key
  end

  def llm_rb_method
    LLM_SERVICES.fetch self.llm_type.downcase do
      raise NotSupportedLlmError, self.llm_type
    end
  end

  private

  def set_uuid
    self.uuid ||= SecureRandom.uuid
  end

  def initialize_encryptable_api_key
    # encrypted_api_keyが設定されている場合のみ初期化
    @encryptable_api_key ||= EncryptableApiKey.new(encrypted_api_key: encrypted_api_key) if encrypted_api_key.present?
  end
end
