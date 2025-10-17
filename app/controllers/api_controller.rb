class ApiController < ActionController::API
  # Base controller for API endpoints
  # CSRF protection is not required (using token authentication)

  JWT_ALGORITHM = "HS256"

  def current_user
    @current_user ||= User.find_by!(google_id: google_id)
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

  private

  def google_id
    payload = jwt_payload bearer_token
    raise ActionController::ParameterMissing, "google_id is missing" if payload["google_id"].blank?

    payload["google_id"]
  end

  def bearer_token
    header = request.headers["Authorization"]
    return nil unless header.present?

    header.split(" ").last if header.start_with?("Bearer ")
  end

  def jwt_payload(token)
    raise JWT::DecodeError, "Token is missing" if token.blank?

    JWT.decode(
      token,
      Rails.application.credentials.secret_key_base,
      true,
      algorithm: JWT_ALGORITHM
    ).first
  end
end
