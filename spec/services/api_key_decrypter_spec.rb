require "rails_helper"

RSpec.describe ApiKeyDecrypter do
  let(:kms_client) { instance_double(Aws::KMS::Client) }
  let(:key_id) { "test-key-id" }
  let(:plain_api_key) { "my-secret-api-key" }
  let(:ciphertext_blob) { "encrypted-binary" }
  let(:base64_ciphertext) { Base64.encode64(ciphertext_blob) }

  before do
    allow(Aws::KMS::Client).to receive(:new).and_return(kms_client)
    stub_const("ENV", ENV.to_hash.merge("KMS_KEY_ID" => key_id))
  end

  it "decrypts the Base64 ciphertext using AWS KMS and returns the plain API key" do
    decrypt_response = double("decrypt_response", plaintext: plain_api_key)
    # Confirm that kms_client's decrypt method is called with correct arguments and returns the expected response
    expect(kms_client).to receive(:decrypt).with(key_id: key_id, ciphertext_blob: ciphertext_blob)
                                           .and_return(decrypt_response)

    decrypter = described_class.new
    result = decrypter.decrypt(base64_ciphertext)
    # decrypter.decrypt should return the decrypted plaintext API key
    expect(result).to eq plain_api_key
  end
end
