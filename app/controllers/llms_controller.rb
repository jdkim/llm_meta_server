class LlmsController < ApplicationController
  skip_before_action :authenticate_user!, only: [ :index ]

  def index
    @llms = Llm.includes(:llm_models).all

    respond_to do |format|
      format.html # renders index.html.erb
      format.json do
        render json: {
          llms: @llms.map(&:as_json)
        }
      end
    end
  end
end
