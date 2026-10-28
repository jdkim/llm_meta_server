# Restrict proxy trust to the actual ingress addresses in production. Never
# derive an admission key from an unvalidated X-Forwarded-For header.
#
# The parsing lives in lib/ and is required here on purpose. Initializers run
# before autoloading, so calling an app/ class from this file raised NameError
# at boot — and only in production, because that is the only environment where
# the condition below is true.
require_relative "../../lib/anonymous_trusted_proxies"

if Rails.env.production? || ENV["ANONYMOUS_TRUSTED_PROXIES"].present?
  proxies, defaulted = AnonymousTrustedProxies.from_env(ENV["ANONYMOUS_TRUSTED_PROXIES"])
  Rails.application.config.action_dispatch.trusted_proxies = proxies
  if defaulted
    Rails.logger.warn "[AnonymousUsage] ANONYMOUS_TRUSTED_PROXIES is not set; " \
                      "trusting loopback only. Set it if the ingress is not on this host."
  end
end
