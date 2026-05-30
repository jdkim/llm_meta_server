require "rails_helper"

# Direct tests for the Google ID token verifier. Every other spec stubs
# this class at its `verify_all` entry point, so if its real audience /
# expiry / payload-validation logic regresses, none of the E2E tests
# would notice. The cases here lock in:
#
#   * Pre-validation (token presence, env-var presence)
#   * Pre-verify JWT exception propagation (so the ApiController can map
#     them to specific HTTP statuses)
#   * Multi-client-ID iteration (any one matching audience wins)
#   * Payload validation: email_verified must be true, sub must be present
#
# JWT.decode and Google::Auth::IDTokens.verify_oidc are stubbed so the
# test doesn't need a real RSA keypair or network access.
RSpec.describe GoogleIdTokenVerifier do
  let(:token) { "header.payload.signature" }
  let(:fake_jwks) { instance_double(JWT::JWK::Set) }

  before do
    # Bypass the JWKS fetch (https://www.googleapis.com/oauth2/v3/certs).
    allow(described_class).to receive(:google_cert_jwks).and_return(fake_jwks)
  end

  # Helper: build a valid Google-style ID token payload.
  def valid_payload(overrides = {})
    {
      "sub" => "google-uid-123",
      "email" => "u@example.com",
      "email_verified" => true,
      "aud" => "client-a.apps.googleusercontent.com",
      "iss" => "https://accounts.google.com"
    }.merge(overrides)
  end

  describe ".verify_all argument validation" do
    it "raises ArgumentError when the token is nil" do
      expect { described_class.verify_all(nil) }.to raise_error(ArgumentError, /Token is required/)
    end

    it "raises ArgumentError when the token is blank" do
      expect { described_class.verify_all("   ") }.to raise_error(ArgumentError, /Token is required/)
    end

    it "raises ArgumentError when ALLOWED_GOOGLE_CLIENT_IDS is unset" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ALLOWED_GOOGLE_CLIENT_IDS").and_return(nil)
      allow(JWT).to receive(:decode) # pre_verify still runs; make it a no-op

      expect { described_class.verify_all(token) }
        .to raise_error(ArgumentError, /ALLOWED_GOOGLE_CLIENT_IDS environment variable is not set/)
    end
  end

  describe ".verify_all pre-verification" do
    before do
      stub_const("ENV", ENV.to_hash.merge("ALLOWED_GOOGLE_CLIENT_IDS" => "client-a"))
    end

    it "lets JWT::ExpiredSignature propagate up (ApiController turns it into 400)" do
      allow(JWT).to receive(:decode).and_raise(JWT::ExpiredSignature, "expired")

      expect { described_class.verify_all(token) }.to raise_error(JWT::ExpiredSignature)
    end

    it "lets JWT::DecodeError propagate up (ApiController turns it into 401)" do
      allow(JWT).to receive(:decode).and_raise(JWT::DecodeError, "bad signature")

      expect { described_class.verify_all(token) }.to raise_error(JWT::DecodeError)
    end
  end

  describe ".verify_all happy path" do
    let(:payload) { valid_payload }

    before do
      allow(JWT).to receive(:decode) # pre_verify succeeds
    end

    it "returns the payload when verify_oidc accepts the only configured client_id" do
      stub_const("ENV", ENV.to_hash.merge("ALLOWED_GOOGLE_CLIENT_IDS" => "client-a"))
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .with(token, aud: "client-a").and_return(payload)

      expect(described_class.verify_all(token)).to eq(payload)
    end

    it "iterates through all configured client_ids until one verifies (audience fallback)" do
      stub_const("ENV", ENV.to_hash.merge("ALLOWED_GOOGLE_CLIENT_IDS" => "client-a, client-b , client-c"))
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .with(token, aud: "client-a")
        .and_raise(Google::Auth::IDTokens::AudienceMismatchError, "wrong aud")
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .with(token, aud: "client-b").and_return(payload)
      # client-c should never be tried — verify_oidc must not be called for it
      allow(Google::Auth::IDTokens).to receive(:verify_oidc).with(token, aud: "client-c")

      expect(described_class.verify_all(token)).to eq(payload)

      expect(Google::Auth::IDTokens).to have_received(:verify_oidc).with(token, aud: "client-a")
      expect(Google::Auth::IDTokens).to have_received(:verify_oidc).with(token, aud: "client-b")
      expect(Google::Auth::IDTokens).not_to have_received(:verify_oidc).with(token, aud: "client-c")
    end

    it "returns nil when every client_id rejects the token" do
      stub_const("ENV", ENV.to_hash.merge("ALLOWED_GOOGLE_CLIENT_IDS" => "client-a,client-b"))
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .and_raise(Google::Auth::IDTokens::AudienceMismatchError, "wrong aud")

      expect(described_class.verify_all(token)).to be_nil
    end

    it "swallows IssuerMismatchError and AuthorizedPartyMismatchError as 'rejected by this client_id'" do
      stub_const("ENV", ENV.to_hash.merge("ALLOWED_GOOGLE_CLIENT_IDS" => "client-a,client-b"))
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .with(token, aud: "client-a")
        .and_raise(Google::Auth::IDTokens::IssuerMismatchError, "bad iss")
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .with(token, aud: "client-b")
        .and_raise(Google::Auth::IDTokens::AuthorizedPartyMismatchError, "bad azp")

      expect(described_class.verify_all(token)).to be_nil
    end
  end

  describe ".verify_all payload validation" do
    before do
      allow(JWT).to receive(:decode)
      stub_const("ENV", ENV.to_hash.merge("ALLOWED_GOOGLE_CLIENT_IDS" => "client-a"))
    end

    it "rejects a payload where email_verified is false (treated as a verification failure)" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .and_return(valid_payload("email_verified" => false))

      expect(described_class.verify_all(token)).to be_nil
    end

    it "rejects a payload where sub is missing" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .and_return(valid_payload("sub" => nil))

      expect(described_class.verify_all(token)).to be_nil
    end

    it "rejects a payload where sub is blank" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .and_return(valid_payload("sub" => "   "))

      expect(described_class.verify_all(token)).to be_nil
    end
  end

  describe "#verify (instance)" do
    let(:payload) { valid_payload }

    it "returns the payload from verify_oidc when validation passes" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .with(token, aud: "client-a").and_return(payload)

      expect(described_class.new("client-a", token).verify).to eq(payload)
    end

    it "returns nil when verify_oidc raises a VerificationError" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .and_raise(Google::Auth::IDTokens::VerificationError, "signature failed")

      expect(described_class.new("client-a", token).verify).to be_nil
    end
  end
end
