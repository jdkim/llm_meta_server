class Users::SessionsController < Devise::SessionsController
  def destroy
    # Delete session
    if current_user
      sign_out(current_user)
      reset_session
    end

    redirect_to "/users/sessions/sso_logout"
  end

  def sso_logout
    # Display SSO sign out confirmation page
    @provider = :google_oauth2
    @provider_name = "Google"
    @logout_url = "https://accounts.google.com/logout"

    render "sso_logout"
  end
end
