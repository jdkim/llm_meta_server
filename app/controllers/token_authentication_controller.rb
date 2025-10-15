class TokenAuthenticationController < ApiController
  # No CSRF protection and authentication required for API controller

  JWT_ALGORITHM = "HS256"

  def create
    jwt_payload = decode_jwt params[:token]
    user = User.find_by!(google_id: jwt_payload["google_id"])

    render_llm_api_keys user
  end

  private

  def decode_jwt(token)
    JWT.decode(
      token,
      Rails.application.credentials.secret_key_base,
      true,
      algorithm: JWT_ALGORITHM
    ).first
  end

  def render_llm_api_keys(user)
    render json: {
      llm_api_keys: user.llm_api_keys.as_json(
        only: [ :uuid, :llm_type, :description, :created_at, :updated_at ]
      )
    }
  end
end
