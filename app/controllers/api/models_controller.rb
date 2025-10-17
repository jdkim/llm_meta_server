
class Api::ModelsController < ApiController
  rescue_from JWT::DecodeError, with: :invalid_token
  rescue_from JWT::ExpiredSignature, with: :expired_signature
  rescue_from ActionController::ParameterMissing, with: :parameter_missing
  rescue_from ActiveRecord::RecordNotFound, with: :unauthorized

  def index
    uuid = expected_params

    llm_api_key = current_user.find_llm_api_key(uuid: uuid)
    models = LlmRbFacade.models llm_api_key

    render json: {
      llm_models: models
    }
  end

  private

  def expected_params
    params.expect(:llm_api_key_uuid)
  end
end
