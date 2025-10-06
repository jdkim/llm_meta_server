class EncryptableApiKey
  # Specify either plain_api_key or encrypted_api_key (both cannot be specified)
  def initialize(plain_api_key: nil, encrypted_api_key: nil)
    raise ArgumentError, "Specify either plain_api_key or encrypted_api_key" if plain_api_key && encrypted_api_key
    raise ArgumentError, "Either plain_api_key or encrypted_api_key must be specified" if !plain_api_key && !encrypted_api_key
    @plain_src     = plain_api_key if plain_api_key.present?
    @encrypted_src = encrypted_api_key if encrypted_api_key.present?
  end

  # Plain text (if not available, decrypt and memoize)
  def plain_api_key
    @plain ||= @plain_src || ApiKeyDecrypter.new.decrypt(@encrypted_src)
  end

  # Encrypted (if not available, encrypt and memoize)
  def encrypted_api_key
    @encrypted ||= @encrypted_src || ApiKeyEncrypter.new.encrypt(@plain_src)
  end

  # For debugging: considering confidentiality
  def inspect
    '#<EncryptableApiKey plain_api_key="[REDACTED]" encrypted_api_key="[REDACTED]">'
  end
end
