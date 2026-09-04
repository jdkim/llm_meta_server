# frozen_string_literal: true

module Admin
  # Read-only roster. super_user status comes from the SUPER_USER_EMAILS env
  # allowlist, so it is shown here but not editable from the UI — changing it
  # is deliberately an operator action on the host.
  class UsersController < BaseController
    def index
      @users = User.order(:id).includes(:llm_api_keys, :mcp_servers)
      @super_user_emails = User.super_user_emails
    end
  end
end
