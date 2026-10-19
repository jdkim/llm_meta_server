class LlmApiKey < ApplicationRecord
  belongs_to :user

  validates :uuid, uniqueness: true
  validates :llm_type, presence: true
  validate :llm_type_must_be_supported
  validates :description, length: { maximum: 255 }, allow_blank: true

  before_validation :set_uuid
  before_validation :initialize_encryptable_api_key

  # Maps llm_type to the llm.rb factory method. :bedrock has no LLM.bedrock —
  # it resolves to BedrockClient in LlmRbFacade#create_llm_client, because the
  # OpenAI-compatible Bedrock endpoint needs a host and path override.
  LLM_SERVICES = {
    "openai" => :openai,
    "anthropic" => :anthropic,
    "google" => :gemini,
    "bedrock" => :bedrock
  }.freeze

  # The server's own credential, used when an ANONYMOUS caller picks a model
  # the catalog marks free_access. Ollama needs no key, so this exists purely
  # for hosted models we choose to give away (gpt-oss on Bedrock).
  #
  # Named by uuid in the environment rather than stored as a raw secret, so
  # the key itself stays an ordinary LlmApiKey row: encrypted through the
  # existing KMS path, rotatable from /admin, and visible in one place. The
  # env var holds only an identifier.
  #
  # Deliberately NOT memoized: a rotated or revoked key must take effect on
  # the next request, not after a restart.
  def self.house_key
    uuid = ENV["HOUSE_LLM_API_KEY_UUID"].presence
    return nil if uuid.nil?

    find_by(uuid: uuid)
  end

  def encryptable_api_key
    @encryptable_api_key ||= EncryptableApiKey.new(encrypted_api_key: encrypted_api_key)
  end

  def encryptable_api_key=(encryptable_api_key)
    raise ArgumentError, "encryptable_api_key cannot be nil" if encryptable_api_key.nil?

    @encryptable_api_key = encryptable_api_key
    self.encrypted_api_key = encryptable_api_key.encrypted_api_key
  end

  def llm_rb_method
    LLM_SERVICES[self.llm_type.downcase]
  end

  def llm_type_for_display
    self.class.format_llm_type(self[:llm_type])
  end

  def as_json(options = {})
    favorited      = user&.favorite_model_meta_ids || []
    default_meta   = user&.default_model_meta_id
    models = LlmModelMap.available_models_for(llm_type).map do |m|
      m.merge(
        "favorite" => favorited.include?(m["value"]),
        "default"  => default_meta.present? && default_meta == m["value"]
      )
    end

    super({ only: %i[uuid llm_type description] }.merge(options))
      .merge(
        "description" => "[#{self.class.format_llm_type(llm_type)}] #{description}",
        "available_models" => models
      )
  end

  def self.format_llm_type(llm_type)
    llm_type.capitalize.gsub("Openai", "OpenAI")
  end

  def self.llm_types_for_select
    LLM_SERVICES.keys.map { |type| [ type.capitalize.gsub("Openai", "OpenAI"), type ] }
  end

  private

  def set_uuid
    self.uuid ||= SecureRandom.uuid
  end

  def initialize_encryptable_api_key
    # encrypted_api_keyが設定されている場合のみ初期化
    @encryptable_api_key ||= EncryptableApiKey.new(encrypted_api_key: encrypted_api_key) if encrypted_api_key.present?
  end

  def llm_type_must_be_supported
    return if llm_type.blank?

    unless LLM_SERVICES.keys.include?(llm_type)
      errors.add(:llm_type, "#{llm_type} is not a supported LLM type")
    end
  end
end
