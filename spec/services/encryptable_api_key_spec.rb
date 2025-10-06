require "rails_helper"

RSpec.describe EncryptableApiKey do
  let(:plain_key) { "sk-test-api-key-12345" }
  let(:encrypted_key) { "base64-encoded-encrypted-key" }
  let(:decrypter) { instance_double(ApiKeyDecrypter) }
  let(:encrypter) { instance_double(ApiKeyEncrypter) }

  before do
    allow(ApiKeyDecrypter).to receive(:new).and_return(decrypter)
    allow(ApiKeyEncrypter).to receive(:new).and_return(encrypter)
  end

  describe "#initialize" do
    context "when both plain_api_key and encrypted_api_key are specified" do
      it "raises ArgumentError" do
        expect {
          described_class.new(plain_api_key: plain_key, encrypted_api_key: encrypted_key)
        }.to raise_error(ArgumentError, "Specify either plain_api_key or encrypted_api_key")
      end
    end

    context "when neither plain_api_key nor encrypted_api_key is specified" do
      it "raises ArgumentError" do
        expect {
          described_class.new
        }.to raise_error(ArgumentError, "Either plain_api_key or encrypted_api_key must be specified")
      end
    end

    context "when only plain_api_key is specified" do
      it "does not raise an error" do
        expect {
          described_class.new(plain_api_key: plain_key)
        }.not_to raise_error
      end
    end

    context "when only encrypted_api_key is specified" do
      it "does not raise an error" do
        expect {
          described_class.new(encrypted_api_key: encrypted_key)
        }.not_to raise_error
      end
    end
  end

  describe "#plain_api_key" do
    context "when initialized with plain_api_key" do
      it "returns the plain API key directly" do
        subject = described_class.new(plain_api_key: plain_key)
        expect(subject.plain_api_key).to eq(plain_key)
      end

      it "does not call decrypter because plain key is already set" do
        subject = described_class.new(plain_api_key: plain_key)
        expect(decrypter).not_to receive(:decrypt)
        subject.plain_api_key
      end

      it "memoizes the result" do
        subject = described_class.new(plain_api_key: plain_key)
        first_call = subject.plain_api_key
        second_call = subject.plain_api_key
        expect(first_call.object_id).to eq(second_call.object_id)
      end
    end

    context "when initialized with encrypted_api_key" do
      it "decrypts and returns the plain API key" do
        allow(decrypter).to receive(:decrypt).with(encrypted_key).and_return(plain_key)
        subject = described_class.new(encrypted_api_key: encrypted_key)
        expect(subject.plain_api_key).to eq(plain_key)
      end

      it "calls decrypter only once (memoization)" do
        allow(decrypter).to receive(:decrypt).with(encrypted_key).and_return(plain_key)
        subject = described_class.new(encrypted_api_key: encrypted_key)

        expect(decrypter).to receive(:decrypt).once.and_return(plain_key)
        subject.plain_api_key
        subject.plain_api_key # Second call should use memoized value
      end
    end
  end

  describe "#encrypted_api_key" do
    context "when initialized with encrypted_api_key" do
      it "returns the encrypted API key directly" do
        subject = described_class.new(encrypted_api_key: encrypted_key)
        expect(subject.encrypted_api_key).to eq(encrypted_key)
      end

      it "does not call encrypter because encrypted_key is already set" do
        subject = described_class.new(encrypted_api_key: encrypted_key)
        expect(encrypter).not_to receive(:encrypt)
        subject.encrypted_api_key
      end
    end

    context "when initialized with plain_api_key" do
      it "encrypts and returns the encrypted API key" do
        allow(encrypter).to receive(:encrypt).with(plain_key).and_return(encrypted_key)
        subject = described_class.new(plain_api_key: plain_key)
        expect(subject.encrypted_api_key).to eq(encrypted_key)
      end
    end
  end

  describe "#inspect" do
    context "to prevent API key leakage in logs" do
      it "redacts plain_api_key when initialized with plain_api_key" do
        subject = described_class.new(plain_api_key: plain_key)
        inspect_result = subject.inspect

        expect(inspect_result).to include("[REDACTED]")
        expect(inspect_result).not_to include(plain_key)
      end

      it "redacts encrypted_api_key when initialized with encrypted_api_key" do
        subject = described_class.new(encrypted_api_key: encrypted_key)
        inspect_result = subject.inspect

        expect(inspect_result).to include("[REDACTED]")
        expect(inspect_result).not_to include(encrypted_key)
      end

      it "returns a consistent format" do
        subject = described_class.new(plain_api_key: plain_key)
        expect(subject.inspect).to eq('#<EncryptableApiKey plain_api_key="[REDACTED]" encrypted_api_key="[REDACTED]">')
      end
    end
  end

  describe "security considerations" do
    it "does not expose plain API key in error messages" do
      subject = described_class.new(plain_api_key: plain_key)

      # When an exception occurs, inspect should not reveal the actual key
      expect(subject.to_s).not_to include(plain_key)
    end

    it "does not expose encrypted API key in error messages" do
      subject = described_class.new(encrypted_api_key: encrypted_key)

      expect(subject.to_s).not_to include(encrypted_key)
    end
  end
end
