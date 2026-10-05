# Restrict proxy trust to the actual ingress addresses in production. Never
# derive an admission key from an unvalidated X-Forwarded-For header.
if ENV["ANONYMOUS_TRUSTED_PROXIES"].present?
  Rails.application.config.action_dispatch.trusted_proxies =
    ENV.fetch("ANONYMOUS_TRUSTED_PROXIES").split(",").map { |address| IPAddr.new(address.strip) }
end
