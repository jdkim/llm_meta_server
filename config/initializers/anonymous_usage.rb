# Restrict proxy trust to the actual ingress addresses in production. Never
# derive an admission key from an unvalidated X-Forwarded-For header.
if Rails.env.production? || ENV["ANONYMOUS_TRUSTED_PROXIES"].present?
  proxies, defaulted = AdmissionClientIp.trusted_proxies_from_env(ENV["ANONYMOUS_TRUSTED_PROXIES"])
  Rails.application.config.action_dispatch.trusted_proxies = proxies
  if defaulted
    Rails.logger.warn "[AnonymousUsage] ANONYMOUS_TRUSTED_PROXIES is not set; " \
                      "trusting loopback only. Set it if the ingress is not on this host."
  end
end
