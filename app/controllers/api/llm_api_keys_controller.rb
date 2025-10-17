class Api::LlmApiKeysController < ApiController
  # No CSRF protection and authentication required for API controller

  rescue_from JWT::DecodeError, with: :invalid_token
  rescue_from JWT::ExpiredSignature, with: :expired_signature
  rescue_from ActionController::ParameterMissing, with: :parameter_missing
  rescue_from ActiveRecord::RecordNotFound, with: :unauthorized

  def index
    render_llm_api_keys current_user
  end

  private

  def render_llm_api_keys(user)
    render json: {
      llm_api_keys: user.llm_api_keys.as_json
    }
  end
end
