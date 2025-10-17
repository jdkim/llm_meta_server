
class Api::ModelsController < ApiController
  rescue_from JWT::DecodeError, with: :invalid_token
  rescue_from JWT::ExpiredSignature, with: :expired_signature
  rescue_from ActionController::ParameterMissing, with: :parameter_missing
  rescue_from ActiveRecord::RecordNotFound, with: :unauthorized

  CHAT_COMPATIBLE_MODELS = [
    # 現行メインライン
    "gpt-4o",          # 最新 GPT-4 Omni
    "gpt-4o-mini",     # 軽量版
    "gpt-4-turbo",     # 旧4系 (turbo)
    "gpt-3.5-turbo",   # 安価で軽い旧モデル
    "gpt-3.5-turbo-16k",

    # reasoning 系 (Responses/Chat どちらでも可)
    "o1",              # reasoning モデル（2025）
    "o1-mini",
    "o3-mini",

    # 企業プランなどで限定的に利用可能な場合
    "gpt-4.1",
    "gpt-4.1-mini",

    # fine-tuning された chat 対応モデル
    "ft:gpt-4o",
    "ft:gpt-4o-mini",
    "ft:gpt-3.5-turbo",
  ]

  def index
    uuid = expected_params

    llm_api_key = current_user.find_llm_api_key(uuid: uuid)
    models = LlmRbFacade.models llm_api_key

    render json: {
      llm_models: models.filter { |model| CHAT_COMPATIBLE_MODELS.include?(model) }
    }
  end

  private

  def expected_params
    params.expect(:llm_api_key_uuid)
  end
end
