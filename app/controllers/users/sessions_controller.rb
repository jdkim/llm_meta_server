class Users::SessionsController < Devise::SessionsController
  # Delete web application session and redirect to sso_logout action.
  def destroy
    # Delete session
    if current_user
      sign_out(current_user)
      reset_session
    end

    redirect_to "/users/sessions/sso_logout"
  end

  # Open a view with a button that allows signing out from Google account.
  def sso_logout
    # Display SSO sign out confirmation page
    @provider = :google_oauth2
    @provider_name = "Google"
    @logout_url = "https://accounts.google.com/logout"

    render "sso_logout"
  end
end
