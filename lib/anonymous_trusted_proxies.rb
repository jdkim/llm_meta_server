require "ipaddr"

# Parses ANONYMOUS_TRUSTED_PROXIES for the initializer.
#
# This lives in lib/ and is required explicitly, NOT in app/ where Zeitwerk
# would autoload it. A config initializer runs before autoloading is set up, so
# naming an app/ constant there raises NameError at boot — in production only,
# which is where this initializer's body is the only one that runs.
module AnonymousTrustedProxies
  # Honouring a forwarded chain from the LOOPBACK peer is not a trust decision
  # about the internet: a request whose TCP peer is 127.0.0.1 came from this
  # host, which is where nginx runs. This is the default because the
  # alternative silently merges every visitor into one quota bucket — with one
  # concurrent request per IP, that is one anonymous request at a time for the
  # whole internet, and the symptom reads as a bug rather than a missing
  # variable.
  LOOPBACK = %w[127.0.0.1/32 ::1/128].freeze

  # Returns [proxies, defaulted]. The caller logs the default so an operator
  # who meant to configure an ingress finds out.
  def self.from_env(value)
    configured = value.to_s.split(",").map(&:strip).reject(&:empty?)
    return [ configured.map { |address| IPAddr.new(address) }, false ] if configured.any?

    [ LOOPBACK.map { |address| IPAddr.new(address) }, true ]
  end
end
