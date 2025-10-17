class Api::ChatsController < ApiController
  rescue_from JWT::DecodeError, with: :invalid_token
  rescue_from JWT::ExpiredSignature, with: :expired_signature
  rescue_from ActiveRecord::RecordNotFound, with: :unauthorized

  def create
    uuid, model_name, prompt = expected_params
    llm_api_key = current_user.find_llm_api_key! uuid
    message = LlmRbFacade.call llm_api_key, model_name, prompt

    render json: {
      response: {
        message: message
      }
    }
  end

  private

  def expected_params
    params.expect(:llm_api_key_uuid, :model_name, :prompt)
  end
end
