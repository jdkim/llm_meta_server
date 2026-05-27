class ModelsController < ApplicationController
  before_action :authenticate_user!

  def index
    # Only show providers the user actually has access to (their registered
    # API keys + Ollama, which never requires a key).
    available = current_user.llm_api_keys.pluck(:llm_type).uniq + [ "ollama" ]
    @groups = LlmModelMap::MODEL_MAP
                .select { |llm_type, _| available.include?(llm_type) }
                .map do |llm_type, models|
      [
        llm_type,
        models.map do |meta_id, info|
          {
            meta_id: meta_id,
            display_name: info[:display_name],
            kind: info[:kind],
            supports_vision: info[:supports_vision] == true,
            favorite: current_user.favorite_model?(meta_id)
          }
        end
      ]
    end
  end

  def toggle_favorite
    meta_id = params[:id].to_s
    unless valid_meta_id?(meta_id)
      redirect_to models_path, alert: "Unknown model."
      return
    end

    favorited = current_user.toggle_favorite_model!(meta_id)
    redirect_to models_path,
                notice: favorited ? "Added to favorites." : "Removed from favorites."
  end

  private

  def valid_meta_id?(meta_id)
    LlmModelMap::MODEL_MAP.any? { |_, models| models.key?(meta_id) }
  end
end
