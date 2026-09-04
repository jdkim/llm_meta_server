# frozen_string_literal: true

# Shared gate for the service-management UI.
#
# Deliberately reuses `super_user?` rather than introducing a separate admin
# role: the operator running the service is the same person using it, and
# forcing an account switch to manage models would be friction with no
# security benefit here. Non-super-users get a 404 so the section's existence
# is not leaked — same posture as AdminController.
module Admin
  class BaseController < ApplicationController
    before_action :authenticate_user!
    before_action :require_super_user!

    layout "application"

    private

    def require_super_user!
      raise ActionController::RoutingError, "Not Found" unless current_user&.super_user?
    end
  end
end
