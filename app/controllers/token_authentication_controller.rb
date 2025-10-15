class TokenAuthenticationController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [ :create ]
  skip_before_action :authenticate_user!, only: [ :create ]

  # POST /auth/token
  def create
    jwt_payload = decode_jwt(params[:token])
    user = User.find_by!(google_id: jwt_payload["google_id"])

    case jwt_payload["action"]
    when "llm_api_keys"
      @llm_api_keys = user.llm_api_keys
      render json: {
        llm_api_keys: @llm_api_keys.map { |api_key|
          {
            uuid: api_key.uuid,
            llm_type: api_key.llm_type,
            description: api_key.description,
            created_at: api_key.created_at,
            updated_at: api_key.updated_at
          }
        }
      }
      # when 'relay'
      #   redirect_to user_relay_path(user)
    else
      render json: { error: "Invalid redirect destination" }, status: :bad_request
    end
  rescue JWT::DecodeError => e
    render json: { error: "Invalid token", message: e.message }, status: :unauthorized
  rescue ActiveRecord::RecordNotFound
    render json: { error: "User not found" }, status: :not_found
  end

  private

  def decode_jwt(token)
    JWT.decode(token, Rails.application.credentials.secret_key_base, true, algorithm: "HS256").first
  end
end
