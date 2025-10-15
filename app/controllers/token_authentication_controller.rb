class TokenAuthenticationController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [ :create ]
  skip_before_action :authenticate_user!, only: [ :create ]

  JWT_ALGORITHM = "HS256"

  def create
    jwt_payload = decode_jwt params[:token]
    user = User.find_by!(google_id: jwt_payload["google_id"])

    handle_action jwt_payload["action"], user
  rescue JWT::DecodeError => e
    render json: { error: "Invalid token", message: e.message }, status: :unauthorized
  rescue ActiveRecord::RecordNotFound
    render json: { error: "User not found" }, status: :not_found
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

  def handle_action(action, user)
    case action
    when "llm_api_keys"
      render_llm_api_keys user
    else
      render json: { error: "Invalid redirect destination" }, status: :bad_request
    end
  end

  def render_llm_api_keys(user)
    render json: {
      llm_api_keys: user.llm_api_keys.as_json(
        only: [:uuid, :llm_type, :description, :created_at, :updated_at]
      )
    }
  end
end
