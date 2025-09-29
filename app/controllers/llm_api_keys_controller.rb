class LlmApiKeysController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user

  # GET /user/:user_id/keys
  def index
    @llm_api_keys = @user.llm_api_keys
  end


  private

  def set_user
    @user = current_user
  end
end
