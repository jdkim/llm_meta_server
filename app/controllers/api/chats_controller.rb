class Api::ChatsController < ApiController
  rescue_from JWT::DecodeError, with: :invalid_token
  rescue_from JWT::ExpiredSignature, with: :expired_signature
  rescue_from ActiveRecord::RecordNotFound, with: :unauthorized
  rescue_from LLM::RateLimitError, with: :rate_limit_error

  def create
    uuid, model_name, prompt = expected_params
    llm_api_key = current_user.llm_api_keys.find_by!(uuid: uuid)
    message = LlmRbFacade.call! llm_api_key, model_name, prompt

    render json: {
      response: {
        message: message
      }
    }
  end

  private

  def rate_limit_error(exception)
    render json: { error: "Rate limit exceeded", message: exception.message }, status: :too_many_requests
  end

  def expected_params
    params.expect(:llm_api_key_uuid, :model_name, :prompt)
  end
end
