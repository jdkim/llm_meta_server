class Api::LlmGatewayController < ApiController
  def create
    uuid = llm_api_key_uuid
    llm_api_key = current_user.llm_api_keys.find_by!(uuid: uuid)
    message = LlmRbFacade.call llm_api_key, model_name, prompt

    render json: {
      response: {
        message: message
      }
    }
  end

  private

  def llm_api_key_uuid
    raise ParameterMissing, "llm_api_key_uuid is missing" if payload["llm_api_key_uuid"].blank?

    payload["llm_api_key_uuid"]
  end

  def model_name
    raise ParameterMissing, "model_name is missing" if payload["model_name"].blank?

    payload["model_name"]
  end

  def prompt
    raise ParameterMissing, "prompt is missing" if payload["prompt"].blank?

    payload["prompt"]
  end

  def payload
    @payload ||= jwt_payload bearer_token
  end
end
