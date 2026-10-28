require_relative "../services/google_id_token_verifier"

class ApiController < ActionController::API
  # Declared here, before Rack::ETag sees the response, so Rack does not add its
  # "max-age=0, private, must-revalidate" default. An action that needs
  # something else sets it afterwards: the SSE endpoints use "no-cache".
  #
  # The matching ETag strip is in ApiNoStore, which has to run outside
  # Rack::ETag to undo what it adds. Both exist because a conditional request
  # that reaches us is answered 304 with no body, and a client gating on
  # fetch's `response.ok` reads that as an empty payload. Our widget lost the
  # model's context window and the hub tool list that way on every repeat
  # visit.
  before_action { response.headers["Cache-Control"] = "no-store" }

  before_action :validate_supplied_authorization

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

  def validate_supplied_authorization
    return if request.headers["Authorization"].nil?
    unless bearer_token
      render json: { error: "Invalid authorization header" }, status: :unauthorized
      return
    end
    current_user
  end

  def google_provider_id
    payload = verify_google_id_token bearer_token
    raise Google::Auth::IDTokens::AudienceMismatchError, "Audience mismatch" if payload.nil?
    sub = payload["sub"]
    raise ActionController::ParameterMissing, "Google Provider ID (sub) is missing" if sub.blank?

    sub
  end

  # Parses "Bearer <token>" per RFC 6750. The token captures any non-empty
  # run of non-whitespace characters after one or more spaces — keeps the
  # token intact even with leading/trailing whitespace and rejects an empty
  # token instead of returning the literal string "Bearer".
  def bearer_token
    header = request.headers["Authorization"]
    return nil unless header.present?

    m = header.match(/\ABearer +(\S+)\s*\z/)
    m && m[1]
  end

  def verify_google_id_token(token)
    raise ActionController::ParameterMissing, "Token is missing" if token.blank?
    GoogleIdTokenVerifier.verify_all token
  end
end
