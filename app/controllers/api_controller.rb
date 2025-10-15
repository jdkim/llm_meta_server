class ApiController < ActionController::API
  # Base controller for API endpoints
  # CSRF protection is not required (using token authentication)

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found
  rescue_from JWT::DecodeError, with: :invalid_token

  private

  def record_not_found(exception)
    render json: { error: "Record not found", message: exception.message }, status: :unauthorized
  end

  def invalid_token(exception)
    render json: { error: "Invalid token", message: exception.message }, status: :unauthorized
  end
end
