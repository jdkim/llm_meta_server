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
      Rails.logger.debug "Token audience mismatch for client_id #{@client_id}: #{e.message}"
      nil
    rescue Google::Auth::IDTokens::AuthorizedPartyMismatchError => e
      Rails.logger.debug "Token authorized party mismatch for client_id #{@client_id}: #{e.message}"
      nil
    rescue Google::Auth::IDTokens::IssuerMismatchError => e
      Rails.logger.debug "Token issuer mismatch for client_id #{@client_id}: #{e.message}"
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

      pre_verify token

      payload = nil
      client_ids = parse_client_ids
      client_ids.any? do |client_id|
        payload = new(client_id, token).verify
      end
      payload
    end

    private

    # Pre-verify JWT token
    #
    # This method performs basic JWT validation (signature, expiration, issuer, etc.)
    # before calling Google::Auth::IDTokens.verify_oidc.
    # This enables early detection of exceptions such as JWT::DecodeError and
    # JWT::ExpiredSignature, allowing for more detailed error handling.
    #
    # @param token [String] The Google ID token to verify (in JWT format)
    # @return [nil] Returns nil if verification succeeds (only when no exception is raised)
    # @raise [JWT::DecodeError] If token decoding fails
    # @raise [JWT::ExpiredSignature] If token has expired
    # @raise [JWT::VerificationError] If signature verification fails
    # @raise [RuntimeError] If fetching Google's public keys fails
    def pre_verify(token)
      # Fetch Google's public keys
      # Google provides public keys via a JWKS (JSON Web Key Set) endpoint,
      # which is used to verify the token's signature
      url = URI.parse("https://www.googleapis.com/oauth2/v3/certs")
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = true
      request = Net::HTTP::Get.new(url.request_uri)
      response = http.request(request)

      # Verify that the HTTP request was successful
      unless response.code.to_i == 200
        raise "Failed to fetch Google's public keys: HTTP #{response.code}"
      end

      # Parse the response body and create a JWKS object
      body = JSON.parse(response.body)
      jwks = JWT::JWK::Set.new(body)

      # Decode and verify the JWT token
      # - algorithms: Only allow RS256 algorithm (signature method used by Google)
      # - jwks: Use the fetched public key set to verify the signature
      # - verify_iss: Enable issuer verification
      # - iss: Expected issuer (only allow Google)
      # - verify_aud: Disable audience verification (validated separately in the verify method)
      JWT.decode token,
                 nil,
                 true,
                 algorithms: ['RS256'],
                 jwks: jwks,
                 verify_iss: true,
                 iss: 'https://accounts.google.com',
                 verify_aud: false
      Rails.logger.debug "JWT token pre-verification passed"
    end

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
