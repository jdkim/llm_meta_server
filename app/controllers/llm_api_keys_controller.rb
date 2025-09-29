class LlmApiKeysController < ApplicationController
  before_action :authenticate_user!

  # GET /user/:user_id/llm_api_keys
  def index
    @llm_api_keys = current_user.llm_api_keys
  end

  # POST /user/:user_id/llm_api_keys
  def create
    llm_type = params[:llm_type]
    api_key = params[:api_key]
    description = params[:description]

    if llm_type.present? && api_key.present?
      begin
        llm_api_key = current_user.llm_api_keys.build(
          uuid: SecureRandom.uuid,
          llm_type: llm_type,
          api_key: api_key,
          description: description
        )
        llm_api_key.save!
        redirect_to user_llm_api_keys_path, notice: "API key has been added successfully"
      rescue => e
        redirect_to user_llm_api_keys_path, method: :get, alert: "Failed to add API key: #{e.message}"
      end
    else
      redirect_to user_llm_api_keys_path, alert: "Please enter LLM type and API key"
    end
  end
end
