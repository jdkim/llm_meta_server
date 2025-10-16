class ApiController < ActionController::API
  # Base controller for API endpoints
  # CSRF protection is not required (using token authentication)

  JWT_ALGORITHM = "HS256"

  def current_user
    payload = jwt_payload(bearer_token)

    @current_user ||= User.find_by!(google_id: payload["google_id"])
  end

  def record_not_found(exception)
    render json: { error: "Record not found", message: exception.message }, status: :unauthorized
  end

  def invalid_token(exception)
    render json: { error: "Invalid token", message: exception.message }, status: :unauthorized
  end

  private

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
