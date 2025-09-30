class LlmApiKeysController < ApplicationController
  before_action :authenticate_user!

  # GET /user/:user_id/llm_api_keys
  def index
    @llm_api_keys = current_user.llm_api_keys
  end

  # POST /user/:user_id/llm_api_keys
  def create
    llm_api_key = current_user.llm_api_keys.build(llm_api_key_params)
    llm_api_key.save!
    redirect_to user_llm_api_keys_path, notice: "API key has been added successfully"
  rescue ActionController::ParameterMissing
    redirect_to user_llm_api_keys_path, alert: "Please enter LLM type and API key"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to user_llm_api_keys_path, method: :get, alert: "Failed to add API key: #{e.message}"
  end

  private

  def llm_api_key_params
    params.expect(llm_api_key: [:llm_type, :api_key, :description])
  end
end
