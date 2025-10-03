class LlmApiKeysController < ApplicationController
  before_action :authenticate_user!

  # GET /user/:user_id/llm_api_keys
  def index
    @llm_api_keys = current_user.llm_api_keys
  end

  # POST /user/:user_id/llm_api_keys
  def create
    current_user.llm_api_keys.create!(llm_api_key_params)
    redirect_to user_llm_api_keys_path, notice: "API key has been added successfully"
  rescue ActionController::ParameterMissing
    redirect_to user_llm_api_keys_path, alert: "Please enter LLM type and API key"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to user_llm_api_keys_path, method: :get, alert: "Failed to add API key: #{e.message}"
  end

  # PATCH/PUT /user/:user_id/llm_api_keys/:id
  def update
    llm_api_key.update!(llm_api_key_params)
    redirect_to user_llm_api_keys_path, update_message_for(llm_api_key)
  rescue ActionController::ParameterMissing
    redirect_to user_llm_api_keys_path, alert: "Please enter API key or description"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to user_llm_api_keys_path, method: :get, alert: "Failed to update API key or description: #{e.message}"
  end

  # DELETE /user/:user_id/llm_api_keys/:id
  def destroy
    llm_type = llm_api_key.llm_type
    description = llm_api_key.description
    if llm_api_key.destroy
      redirect_to user_llm_api_keys_path, notice: "#{llm_type} (#{description}) API key has been deleted successfully"
    else
      redirect_to user_llm_api_keys_path, alert: "Failed to delete API key"
    end
  end

  private

  def update_message_for(llm_api_key)
    if llm_api_key.saved_change_to_encrypted_api_key? && llm_api_key.saved_change_to_description?
      { notice: "API key and description have been updated successfully" }
    elsif llm_api_key.saved_change_to_encrypted_api_key?
      { notice: "API key has been updated successfully" }
    elsif llm_api_key.saved_change_to_description?
      { notice: "Description of API key has been updated successfully" }
    else
      { alert: "Please enter a new API key or description" }
    end
  end

  def llm_api_key_params
    params.expect(llm_api_key: [ :llm_type, :api_key, :description ])
  end

  def llm_api_key
    # Temporarily store in an instance variable to retain dirty information
    @llm_api_key ||= current_user.llm_api_keys.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to user_path(current_user), alert: "The specified API key was not found"
  end
end
