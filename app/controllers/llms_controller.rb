class LlmsController < ApplicationController
  skip_before_action :authenticate_user!, only: [ :index ]

  def index
    @llms = Llm.includes(:llm_models).all

    respond_to do |format|
      format.html # renders index.html.erb
      format.json do
        render json: {
          llms: @llms.map do |llm|
            {
              id: llm.id,
              name: llm.name,
              created_at: llm.created_at,
              updated_at: llm.updated_at,
              models: llm.llm_models.map do |model|
                {
                  name: model.name,
                  display_name: model.display_name,
                  created_at: model.created_at,
                  updated_at: model.updated_at
                }
              end
            }
          end
        }
      end
    end
  end
end

