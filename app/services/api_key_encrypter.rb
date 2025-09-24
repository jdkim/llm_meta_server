# This class handles encryption of API keys using AWS KMS.
class ApiKeyEncrypter
  # Initializes the encrypter with a specific AWS region and KMS key ID.
  # @param region [String] AWS region for KMS client (default: "ap-northeast-1")
  def initialize(region: "ap-northeast-1")
    @aws_kms_client = Aws::KMS::Client.new(region: region)
    @key_id = ENV["KMS_KEY_ID"]
  end

  # Encrypts a plain API key using AWS KMS and returns the Base64-encoded ciphertext.
  # @param plain_api_key [String] The API key to encrypt
  # @return [String] Base64-encoded ciphertext
  def encrypt(plain_api_key)
    resp = @aws_kms_client.encrypt(key_id: @key_id, plaintext: plain_api_key)

    Base64.encode64(resp.ciphertext_blob)
  end
end
