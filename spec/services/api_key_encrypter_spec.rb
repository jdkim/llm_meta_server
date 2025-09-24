require "rails_helper"

RSpec.describe ApiKeyEncrypter do
  let(:kms_client) { instance_double(Aws::KMS::Client) }
  let(:key_id) { "test-key-id" }
  let(:plain_api_key) { "my-secret-api-key" }
  let(:ciphertext_blob) { "encrypted-binary" }
  let(:base64_ciphertext) { Base64.encode64(ciphertext_blob) }

  before do
    allow(Aws::KMS::Client).to receive(:new).and_return(kms_client)
    stub_const("ENV", ENV.to_hash.merge("KMS_KEY_ID" => key_id))
  end

  it "encrypts the API key using AWS KMS and returns Base64 ciphertext" do
    encrypt_response = double("encrypt_response", ciphertext_blob: ciphertext_blob)
    expect(kms_client).to receive(:encrypt).with(key_id: key_id, plaintext: plain_api_key)
                                           .and_return(encrypt_response)

    encrypter = described_class.new
    result = encrypter.encrypt(plain_api_key)
    expect(result).to eq(base64_ciphertext)
  end
end
