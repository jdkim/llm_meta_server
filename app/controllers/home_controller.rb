class HomeController < ApplicationController
  def index
    if user_signed_in?
      # Logged-in users will be redirected to their profile page.
      # redirect_to user_profile_path
    end
  end
end
