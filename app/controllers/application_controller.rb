class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Devise authentication
  before_action :authenticate_user!
  before_action :configure_permitted_parameters, if: :devise_controller?

  protected

  # Devise permitted parameters setting
  # Similar to Rails' Strong Parameters feature, for security reasons
  # Devise also requires explicit permission for parameters.
  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [ :google_id ])
    devise_parameter_sanitizer.permit(:account_update, keys: [ :google_id ])
  end
end
