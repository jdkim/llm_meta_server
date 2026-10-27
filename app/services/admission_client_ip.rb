# Rails RemoteIp assumes requests passed through a proxy. Only use its
# forwarding chain when the actual TCP peer is an explicitly trusted ingress.
module AdmissionClientIp
  # Honouring a forwarded chain from the LOOPBACK peer is not a trust
  # decision about the internet: a request whose TCP peer is 127.0.0.1 came
  # from this host, which is where nginx runs. This is the default because the
  # alternative silently merges every visitor into one quota bucket — with
  # ANONYMOUS_LLM_PER_IP at 1, that means one anonymous request at a time for
  # the whole internet, and the symptom looks like a bug rather than a missing
  # environment variable.
  LOOPBACK = %w[127.0.0.1/32 ::1/128].freeze

  def self.call(request)
    peer = request.get_header("REMOTE_ADDR").to_s
    proxies = Rails.application.config.action_dispatch.trusted_proxies || []
    return request.remote_ip if proxies.any? { |proxy| proxy === peer }
    peer.presence || "unknown"
  end

  # Parsed from the environment so the initializer stays declarative and this
  # stays testable. Returns [proxies, defaulted] — the caller logs the default
  # so an operator who meant to configure an ingress finds out.
  def self.trusted_proxies_from_env(value)
    configured = value.to_s.split(",").map(&:strip).reject(&:blank?)
    return [ configured.map { |address| IPAddr.new(address) }, false ] if configured.any?
    [ LOOPBACK.map { |address| IPAddr.new(address) }, true ]
  end
end
