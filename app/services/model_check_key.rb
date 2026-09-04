# frozen_string_literal: true

# Resolves the API key used to query a provider's list-models endpoint for
# `models:check_updates`.
#
# An explicit MODEL_CHECK_<PROVIDER>_KEY still wins, so an operator can point
# the check at a throwaway key. Otherwise it reuses a key this server already
# stores (KMS-encrypted) for that provider: asking the server which models
# exist should not require copying credentials back out of it first. That
# setup step was the main reason the check never got run routinely.
#
# Prefers a super_user's key — they are the operator maintaining the catalog,
# and it avoids spending an ordinary user's quota on an admin task.
class ModelCheckKey
  # Providers reached without credentials. Ollama is the local server: the
  # check just asks it what has been pulled onto the box.
  KEYLESS_PROVIDERS = %w[ollama].freeze

  Result = Struct.new(:key, :source, :detail, keyword_init: true) do
    def present? = key.present? || source == :not_required
  end

  def self.for(provider)
    if KEYLESS_PROVIDERS.include?(provider.to_s)
      return Result.new(key: nil, source: :not_required, detail: "no key required")
    end

    env = ENV["MODEL_CHECK_#{provider.to_s.upcase}_KEY"].to_s
    return Result.new(key: env, source: :env, detail: "MODEL_CHECK_#{provider.to_s.upcase}_KEY") if env.present?

    record = stored_record_for(provider)
    return Result.new(key: nil, source: :missing, detail: "no stored #{provider} key") if record.nil?

    Result.new(key: record.encryptable_api_key.plain_api_key,
               source: :stored,
               detail: "stored key #{record.uuid} (#{record.user&.email})")
  rescue StandardError => e
    # Decryption needs KMS; a misconfigured environment should degrade to
    # "skipped with a reason", not abort the whole check for other providers.
    Result.new(key: nil, source: :error, detail: "#{e.class}: #{e.message}")
  end

  def self.stored_record_for(provider)
    keys = LlmApiKey.where(llm_type: provider.to_s).order(:id).includes(:user).to_a
    return nil if keys.empty?

    supers = User.super_user_emails
    keys.find { |k| supers.include?(k.user&.email.to_s.downcase) } || keys.first
  end
end
