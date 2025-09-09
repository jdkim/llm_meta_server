class HomeController < ApplicationController
  skip_before_action :authenticate_user!, only: [ :index ]

  def index
    if user_signed_in?
      # Logged-in users will be redirected to their profile page.
      # redirect_to user_profile_path
    end
  end
end
