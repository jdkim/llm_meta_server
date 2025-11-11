class GoogleIdTokenVerifier
  attr_reader :client, :token
  def initialize(client, token)
    @client = client
    @token = token
  end

  def verify
    begin
      payload = Google::Auth::IDTokens.verify_oidc @token, aud: @client_id
      validate_payload payload
      Rails.logger.debug "Token verified successfully with client_id: #{client_id}"
      true
    rescue Google::Auth::IDTokens::VerificationError => e
      Rails.logger.debug "Verification failed with client_id #{client_id}: #{e.message}"
      false
    end
  end

  def self.verify_all(token)
    raise ArgumentError, "Token is required" if token.blank?

    client_ids = parse_client_ids
    client_ids.any? do |client_id|
      new(client_id, token).verify
    end
  end

  private

  def self.parse_client_ids
    ids = ENV["ALLOWED_GOOGLE_CLIENT_IDS"]
    # Use ALLOWED_GOOGLE_CLIENT_IDS if configured, otherwise raise error
    raise ArgumentError, "ALLOWED_GOOGLE_CLIENT_IDS environment variable is not set" if ids.blank?
    ids.split(",").map(&:strip)
  end

  private


  def validate_payload(payload)
    # Check email verification status
    unless payload["email_verified"]
      raise Google::Auth::IDTokens::VerificationError, "Email is not verified"
    end

    # Check existence of sub field (Google Provider ID)
    if payload["sub"].blank?
      raise Google::Auth::IDTokens::VerificationError, "Google Provider ID (sub) is missing"
    end
  end
end
