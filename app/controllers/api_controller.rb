require_relative "../services/google_id_token_verifier"

class ApiController < ActionController::API
  # Base controller for API endpoints
  # CSRF protection is not required (using Google ID Token authentication)
  # CORS is handled by Rack::Cors middleware (see config/initializers/cors.rb)

  rescue_from JWT::DecodeError, with: :invalid_token
  rescue_from JWT::ExpiredSignature, with: :expired_signature
  rescue_from Google::Auth::IDTokens::AudienceMismatchError, with: :unauthorized
  rescue_from Google::Auth::IDTokens::VerificationError, with: :unauthorized
  rescue_from ActionController::ParameterMissing, with: :parameter_missing
  rescue_from ActiveRecord::RecordNotFound, with: :unauthorized

  def current_user
    @current_user ||= User.find_by!(google_id: google_provider_id)
  end

  def unauthorized(exception)
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def invalid_token(exception)
    render json: { error: "Invalid token", message: exception.message }, status: :unauthorized
  end

  def expired_signature(exception)
    render json: { error: "Token has expired", message: exception.message }, status: :bad_request
  end

  def parameter_missing(exception)
    render json: { error: "Parameter missing", message: exception.message }, status: :bad_request
  end

  private

  def google_provider_id
    payload = verify_google_id_token bearer_token
    raise Google::Auth::IDTokens::AudienceMismatchError, "Audience mismatch" if payload.nil?
    sub = payload["sub"]
    raise ActionController::ParameterMissing, "Google Provider ID (sub) is missing" if sub.blank?

    sub
  end

  def bearer_token
    header = request.headers["Authorization"]
    return nil unless header.present?

    header.split(" ").last if header.start_with?("Bearer ")
  end

  def verify_google_id_token(token)
    raise ActionController::ParameterMissing, "Token is missing" if token.blank?
    GoogleIdTokenVerifier.verify_all token
  end
end
