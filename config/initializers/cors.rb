# Be sure to restart your server when you modify this file.

# Handle Cross-Origin Resource Sharing (CORS) for API requests.
#
# The allowlist is DEPLOYMENT configuration, not source: browser origins
# permitted to call the hub's anon API directly (the level-1 widget flow, where
# a widget embedded on a host site calls /api/* from the visitor's browser).
# It lives in CORS_ORIGINS so that adding a host is an environment change
# rather than a commit — which keeps deployment-only hostnames out of this
# public repo, and keeps prod and dev running identical code.
#
#   CORS_ORIGINS=https://a.example,https://b.example,http://localhost:3001
#
# Comma-separated, scheme REQUIRED: Rack::Cors string-matches the Origin
# header, so a bare hostname silently matches nothing. Set it in .env for
# development and in .env.production (loaded by the systemd unit's
# EnvironmentFile) for production; see .env.production.example.
#
# Unset or empty yields an empty allowlist, which allows nothing. That is
# deliberate — a misconfigured deployment breaks widgets loudly instead of
# opening the API to every origin.
CORS_ORIGINS = ENV.fetch("CORS_ORIGINS", "").split(",").map(&:strip).reject(&:empty?).freeze

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*CORS_ORIGINS)

    resource "/api/*",
      headers: :any,
      methods: [ :get, :post ],
      expose: [ "Content-Type", "Authorization", "Retry-After" ],
      credentials: false  # Corresponds to credentials: 'omit'
  end
end
