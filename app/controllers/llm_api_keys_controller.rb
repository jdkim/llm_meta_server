class LlmApiKeysController < ApplicationController
  before_action :authenticate_user!

  # GET /user/:user_id/llm_api_keys
  def index
    @llm_api_keys = current_user.llm_api_keys
  end

  # POST /user/:user_id/llm_api_keys
  def create
    current_user.llm_api_keys.create!(build_llm_api_key_attributes_for_create)
    redirect_to user_llm_api_keys_path, notice: "API key has been added successfully"
  rescue ActionController::ParameterMissing
    redirect_to user_llm_api_keys_path, alert: "Please enter LLM type and API key"
  rescue ArgumentError => e
    redirect_to user_llm_api_keys_path, alert: e.message
  rescue ActiveRecord::RecordInvalid => e
    redirect_to user_llm_api_keys_path, method: :get, alert: "Failed to add API key: #{e.message}"
  end

  # PATCH/PUT /user/:user_id/llm_api_keys/:id
  def update
    llm_api_key.update!(build_llm_api_key_attributes_for_update)
    redirect_to user_llm_api_keys_path, update_message_for(llm_api_key)
  rescue ActionController::ParameterMissing
    redirect_to user_llm_api_keys_path, alert: "Please enter API key or description"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to user_llm_api_keys_path, method: :get, alert: "Failed to update API key or description: #{e.message}"
  end

  # DELETE /user/:user_id/llm_api_keys/:id
  def destroy
    llm_api_key.destroy!
    redirect_to user_llm_api_keys_path, notice: "#{llm_api_key.llm_type} (#{llm_api_key.description}) API key has been deleted successfully"
  rescue ActiveRecord::RecordNotDestroyed
    redirect_to user_llm_api_keys_path, alert: "Failed to delete API key"
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

  def build_llm_api_key_attributes_for_create
    ps = llm_api_key_params
    raise ArgumentError, "API Key can't blank." if ps[:api_key].blank?

    {
      llm_type: ps[:llm_type],
      encryptable_api_key: EncryptableApiKey.new(plain_api_key: ps[:api_key]),
      description: ps[:description]
    }
  end

  def build_llm_api_key_attributes_for_update
    ps = llm_api_key_params
    attributes = {}

    if ps[:api_key].present?
      attributes[:encryptable_api_key] = EncryptableApiKey.new(plain_api_key: ps[:api_key])
    end

    if ps[:description].present?
      attributes[:description] = ps[:description]
    end

    attributes
  end

  def llm_api_key
    # Temporarily store in an instance variable to retain dirty information
    @llm_api_key ||= current_user.llm_api_keys.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to user_path(current_user), alert: "The specified API key was not found"
  end
end
