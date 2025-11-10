class GoogleIdTokenVerifier
  def initialize
    @client_ids = parse_client_ids
  end

  def verify(token)
    raise ArgumentError, "Token is required" if token.blank?
    raise ArgumentError, "Google OAuth client ID is not configured" if @client_ids.blank?

    payload = @client_ids.detect do |client_id|
      begin
        found = Google::Auth::IDTokens.verify_oidc token, aud: client_id
        validate_payload found
        Rails.logger.debug "Token verified successfully with client_id: #{client_id}"
        true
      rescue Google::Auth::IDTokens::VerificationError => e
        Rails.logger.debug "Verification failed with client_id #{client_id}: #{e.message}"
        false
      end
    end

    # If verification failed with all CLIENT_IDs
    raise Google::Auth::IDTokens::VerificationError, "Token verification failed: #{last_error&.message}" unless payload
    payload
  end

  private

  def parse_client_ids
    # Use ALLOWED_GOOGLE_CLIENT_IDS if configured, otherwise raise error
    raise ArgumentError, "ALLOWED_GOOGLE_CLIENT_IDS environment variable is not set" if ENV["ALLOWED_GOOGLE_CLIENT_IDS"].blank?
    ENV["ALLOWED_GOOGLE_CLIENT_IDS"].split(",").map(&:strip)
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
