# frozen_string_literal: true

# Super-user-only dashboard for hub.AIbranch. Gated by User#super_user?
# (env-driven SUPER_USER_EMAILS allowlist). Non-super-users get a 404
# so the route's existence isn't leaked.
class AdminController < ApplicationController
  before_action :authenticate_user!
  before_action :require_super_user!

  def index
    @stats = AdminStats.collect
  end

  private

  def require_super_user!
    raise ActionController::RoutingError, "Not Found" unless current_user&.super_user?
  end
end
