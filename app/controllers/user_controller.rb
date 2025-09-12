class UserController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user, only: [ :show ]

  def show
  end

  private

  def set_user
    @user = current_user
  end

  def user_params
    params.require(:user).permit(:email)
  end
end
