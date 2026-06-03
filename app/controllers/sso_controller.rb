# frozen_string_literal: true

# Deep-link entry point for users coming from a sister service (chat
# service, future services, third-party). If they already have a hub
# session, we redirect immediately. Otherwise we render a tiny HTML
# page that auto-submits the Google OAuth start form, so the visitor
# bounces silently through Google (their Google session is alive
# because the originating service used the same IdP) and lands signed
# in on the hub.
#
# The `?return_to=<path>` parameter, when provided, is honored after
# successful sign-in. Only same-host paths are accepted to prevent
# open-redirect abuse.
class SsoController < ApplicationController
  layout false
  skip_before_action :authenticate_user!, raise: false

  def show
    target = safe_return_to(params[:return_to])

    if user_signed_in?
      redirect_to target
      return
    end

    # Stash the post-sign-in destination in the session so the OAuth
    # callback knows where to land. Devise reads `stored_location_for`.
    store_location_for(:user, target)

    # Renders app/views/sso/show.html.erb — auto-submits the OAuth form.
  end

  private

  # Accept only relative same-host paths; anything else falls back to root.
  def safe_return_to(value)
    return root_path if value.blank?
    uri = URI.parse(value.to_s)
    return root_path if uri.host.present? && uri.host != request.host
    uri.path.presence || root_path
  rescue URI::InvalidURIError
    root_path
  end
end
