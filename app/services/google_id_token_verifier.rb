class GoogleIdTokenVerifier
  attr_reader :client, :token
  def initialize(client_id, token)
    @client_id = client_id
    @token = token
  end

  # Verify token with a single client_id
  def verify
    begin
      payload = Google::Auth::IDTokens.verify_oidc @token, aud: @client_id
      validate_payload payload
      Rails.logger.debug "Token verified successfully with client_id: #{@client_id}"
      payload
    rescue Google::Auth::IDTokens::AudienceMismatchError => e
      nil
    rescue Google::Auth::IDTokens::VerificationError => e
      Rails.logger.debug "Verification failed with client_id #{@client_id}: #{e.message}"
      nil
    end
  end

  class << self
    # Verify token with all client_ids set in environment variables
    def verify_all(token)
      raise ArgumentError, "Token is required" if token.blank?

      payload = nil
      client_ids = parse_client_ids
      client_ids.any? do |client_id|
        payload = new(client_id, token).verify
      end
      payload
    end

    private

    def parse_client_ids
      ids = ENV["ALLOWED_GOOGLE_CLIENT_IDS"]
      # Use ALLOWED_GOOGLE_CLIENT_IDS if configured, otherwise raise error
      raise ArgumentError, "ALLOWED_GOOGLE_CLIENT_IDS environment variable is not set" if ids.blank?
      ids.split(",").map(&:strip)
    end
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
