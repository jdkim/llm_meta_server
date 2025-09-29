class LlmApiKeysController < ApplicationController
  before_action :authenticate_user!

  # GET /user/:user_id/keys
  def index
    @llm_api_keys = current_user.llm_api_keys
  end
end
