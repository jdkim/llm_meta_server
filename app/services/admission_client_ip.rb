# Rails RemoteIp assumes requests passed through a proxy. Only use its
# forwarding chain when the actual TCP peer is an explicitly trusted ingress.
module AdmissionClientIp
  def self.call(request)
    peer = request.get_header("REMOTE_ADDR").to_s
    proxies = Rails.application.config.action_dispatch.trusted_proxies || []
    return request.remote_ip if proxies.any? { |proxy| proxy === peer }
    peer.presence || "unknown"
  end
end
