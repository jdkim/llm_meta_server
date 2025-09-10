class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  def google_oauth2
    @user = User.from_omniauth(request.env["omniauth.auth"])

    # Check if the user was successfully saved to the database
    if @user.persisted?
      # Authentication successful: Set flash message and sign in with redirect
      flash[:notice] = I18n.t "devise.omniauth_callbacks.success", kind: "Google"
      sign_in_and_redirect @user, event: :authentication
    else
      # Authentication failed: User creation/validation errors occurred
      # This happens when:
      # - Email validation fails
      # - Required fields are missing
      # - Database constraints are violated
      # - User model validations fail

      # Redirect to home with error messages
      redirect_to root_path, alert: @user.errors.full_messages.join("\n")
    end
  end

  def failure
    redirect_to root_path, alert: "Failed to authentication. Please try again."
  end
end
