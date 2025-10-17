
class Api::LlmModelsController < ApiController
  rescue_from JWT::DecodeError, with: :invalid_token
  rescue_from JWT::ExpiredSignature, with: :expired_signature
  rescue_from ActionController::ParameterMissing, with: :parameter_missing
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    uuid = llm_api_key_uuid
    llm_api_key = current_user.llm_api_keys.find_by!(uuid: uuid)
    models = LlmRbFacade.models llm_api_key

    render json: {
      llm_models: models
    }
  end

  private

  def llm_api_key_uuid
    raise ActionController::ParameterMissing, "llm_api_key_uuid is missing" if payload["llm_api_key_uuid"].blank?

    payload["llm_api_key_uuid"]
  end

  def payload
    @payload ||= jwt_payload bearer_token
  end

  def parameter_missing(exception)
    render json: { error: "Parameter missing", message: exception.message }, status: :bad_request
  end
end
