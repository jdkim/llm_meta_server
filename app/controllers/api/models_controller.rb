
class Api::ModelsController < ApiController
  rescue_from JWT::DecodeError, with: :invalid_token
  rescue_from JWT::ExpiredSignature, with: :expired_signature
  rescue_from ActionController::ParameterMissing, with: :parameter_missing
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    uuid = expected_params

    llm_api_key = current_user.llm_api_keys.find_by!(uuid: uuid)
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
