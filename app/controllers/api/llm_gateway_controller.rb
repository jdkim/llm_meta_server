class Api::LlmGatewayController < ApiController
  rescue_from JWT::DecodeError, with: :invalid_token
  rescue_from JWT::ExpiredSignature, with: :expired_signature
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def create
    uuid = permitted_params[:llm_api_key_uuid]
    model_name = permitted_params[:model_name]
    prompt = permitted_params[:prompt]

    llm_api_key = current_user.llm_api_keys.find_by!(uuid: uuid)

    message = LlmRbFacade.call llm_api_key, model_name, prompt

    render json: {
      response: {
        message: message
      }
    }
  end

  private

  def permitted_params
    params.permit(:llm_api_key_uuid, :model_name, :prompt)
  end
end
