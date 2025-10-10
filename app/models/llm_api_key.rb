require "llm"

class LlmApiKey < ApplicationRecord
  belongs_to :user

  validates :uuid, uniqueness: true
  validates :llm_type, presence: true
  validates :description, length: { maximum: 255 }, allow_blank: true

  before_validation :set_uuid
  before_validation :initialize_encryptable_api_key

  STRATEGIES = {
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

  def build_llm
    llm_method = STRATEGIES.fetch self.llm_type.downcase do
      raise NotSupportedLlmError, self.llm_type
    end

    # public_send dynamically invokes a public method on an object
    # Example: LLM.public_send(:openai, key: "xxx") is equivalent to LLM.openai(key: "xxx")
    # Unlike send, public_send cannot call private methods (safer)
    # Here, it calls one of :ollama, :openai, :anthropic, or :gemini based on llm_type
    # This eliminates the need for separate files for each LLM service
    LLM.public_send llm_method, key: encryptable_api_key.plain_api_key
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
