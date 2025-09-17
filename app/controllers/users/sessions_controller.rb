class Users::SessionsController < Devise::SessionsController
  # Delete web application session and redirect to sso_logout action.
  def destroy
    # Delete session
    if current_user
      sign_out(current_user)
      reset_session
    end

    flash[:notice] = "You have successfully signed out."
    redirect_to root_path
  end
end
