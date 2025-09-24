class ApiKeyEncrypter
  def initialize(region: "ap-northeast-1")
    @aws_kms_client = Aws::KMS::Client.new(region: region)
    @key_id = ENV["KMS_KEY_ID"]
  end

  def encrypt(plain_api_key)
    resp = @aws_kms_client.encrypt(key_id: @key_id, plaintext: plain_api_key)
    Base64.encode64(resp.ciphertext_blob)
  end
end
