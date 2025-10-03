# This class handles decryption of API keys using AWS KMS.
class ApiKeyDecrypter
  # Initializes the decrypter with a specific AWS region and KMS key ID.
  # @param region [String] AWS region for KMS client (default: "ap-northeast-1")
  def initialize(region: "ap-northeast-1")
    @aws_kms_client = Aws::KMS::Client.new(region: region)
    @key_id = ENV["KMS_KEY_ID"]
  end

  # Decrypts a Base64-encoded ciphertext API key using AWS KMS and returns the plain text.
  # @param encrypted_api_key [String] Base64-encoded ciphertext API key
  # @return [String] The decrypted plain API key
  def decrypt(encrypted_api_key)
    decoded_ciphertext = Base64.decode64(encrypted_api_key)
    resp = @aws_kms_client.decrypt(key_id: @key_id, ciphertext_blob: decoded_ciphertext)

    resp.plaintext
  end
end
