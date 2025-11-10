require "googleauth"
require "googleauth/id_tokens"

class GoogleIdTokenVerifier
  def initialize(client_ids: nil)
    @client_ids = client_ids || parse_client_ids
  end

  def verify(token)
    raise ArgumentError, "Token is required" if token.blank?
    raise ArgumentError, "Google OAuth client ID is not configured" if @client_ids.blank?

    # Try verification with each CLIENT_ID
    last_error = nil
    @client_ids.each do |client_id|
      begin
        # Use official googleauth gem functionality
        payload = Google::Auth::IDTokens.verify_oidc(token, aud: client_id)

        # Additional validation
        validate_payload(payload)

        Rails.logger.debug "Token verified successfully with client_id: #{client_id}"
        return payload
      rescue Google::Auth::IDTokens::VerificationError => e
        last_error = e
        Rails.logger.debug "Verification failed with client_id #{client_id}: #{e.message}"
        next
      end
    end

    # If verification failed with all CLIENT_IDs
    raise Google::Auth::IDTokens::VerificationError, "Token verification failed: #{last_error&.message}"
  rescue ArgumentError
    raise  # Re-raise ArgumentError as is
  rescue StandardError => e
    raise Google::Auth::IDTokens::VerificationError, "Unexpected error: #{e.message}"
  end

  private

  def parse_client_ids
    # Use ALLOWED_GOOGLE_CLIENT_IDS if configured, otherwise use only GOOGLE_CLIENT_ID
    if ENV["ALLOWED_GOOGLE_CLIENT_IDS"].present?
      ENV["ALLOWED_GOOGLE_CLIENT_IDS"].split(",").map(&:strip)
    elsif ENV["GOOGLE_CLIENT_ID"].present?
      [ ENV["GOOGLE_CLIENT_ID"] ]
    else
      []
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
