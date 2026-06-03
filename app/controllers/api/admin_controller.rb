# frozen_string_literal: true

# JSON sibling of AdminController for cross-service stats aggregation.
# Same gating: requires a verified Google ID token (handled by
# ApiController) AND that the resolved user is a super user.
class Api::AdminController < ApiController
  before_action :require_super_user!

  def stats
    render json: AdminStats.collect
  end

  private

  def require_super_user!
    return if current_user&.super_user?
    render json: { error: "Forbidden" }, status: :forbidden
  end
end
