class ApiController < ActionController::API
  # Base controller for API endpoints
  # CSRF protection is not required (using token authentication)

  JWT_ALGORITHM = "HS256"

  def current_user
    jwt_payload = decode_jwt extract_token_from_authorization_header

    @current_user ||= User.find_by!(google_id: jwt_payload["google_id"])
  end

  def record_not_found(exception)
    render json: { error: "Record not found", message: exception.message }, status: :unauthorized
  end

  def invalid_token(exception)
    render json: { error: "Invalid token", message: exception.message }, status: :unauthorized
  end

  private

  def extract_token_from_authorization_header
    header = request.headers["Authorization"]
    return nil unless header.present?

    header.split(" ").last if header.start_with?("Bearer ")
  end

  def decode_jwt(token)
    raise JWT::DecodeError, "Token is missing" if token.blank?

    JWT.decode(
      token,
      Rails.application.credentials.secret_key_base,
      true,
      algorithm: JWT_ALGORITHM
    ).first
  end
end
