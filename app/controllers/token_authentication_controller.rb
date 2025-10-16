class TokenAuthenticationController < ApiController
  # No CSRF protection and authentication required for API controller

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found
  rescue_from JWT::DecodeError, with: :invalid_token

  def llm_api_keys
    jwt_payload = decode_jwt extract_token_from_authorization_header
    user = User.find_by!(google_id: jwt_payload["google_id"])

    render_llm_api_keys user
  end

  private

  def render_llm_api_keys(user)
    render json: {
      llm_api_keys: user.llm_api_keys.as_json(
        only: [ :uuid, :llm_type, :description, :created_at, :updated_at ]
      )
    }
  end
end
