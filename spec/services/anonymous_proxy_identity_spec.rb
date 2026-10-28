require "rails_helper"

RSpec.describe "Anonymous network identity" do
  def client_ip(remote:, forwarded:, proxies: [])
    allow(Rails.application.config.action_dispatch).to receive(:trusted_proxies).and_return(proxies)
    app = ->(env) { [ 200, {}, [ AdmissionClientIp.call(ActionDispatch::Request.new(env)) ] ] }
    middleware = ActionDispatch::RemoteIp.new(app, true, proxies)
    middleware.call(Rack::MockRequest.env_for("/", "REMOTE_ADDR" => remote, "HTTP_X_FORWARDED_FOR" => forwarded))[2].join
  end

  it "ignores forwarded identities from an untrusted public peer" do
    expect(client_ip(remote: "203.0.113.10", forwarded: "198.51.100.99")).to eq("203.0.113.10")
  end

  it "accepts forwarding only from explicitly configured ingress" do
    expect(client_ip(remote: "127.0.0.1", forwarded: "198.51.100.99", proxies: [ IPAddr.new("127.0.0.1/32") ])).to eq("198.51.100.99")
  end
end

RSpec.describe AdmissionClientIp, ".trusted_proxies_from_env" do
  it "parses an explicitly configured ingress list" do
    proxies, defaulted = described_class.trusted_proxies_from_env("10.0.0.5, 127.0.0.1/32")

    expect(proxies.map(&:to_s)).to eq([ "10.0.0.5", "127.0.0.1" ])
    expect(defaulted).to be(false)
  end

  it "falls back to loopback, and says so, when the variable is missing" do
    # Without this the list is empty, nothing is trusted, and every visitor
    # behind the local nginx is accounted for as 127.0.0.1 — one shared bucket.
    [ nil, "", "  ", "," ].each do |value|
      proxies, defaulted = described_class.trusted_proxies_from_env(value)

      expect(proxies.map(&:to_s)).to eq([ "127.0.0.1", "::1" ]), "for #{value.inspect}"
      expect(defaulted).to be(true), "for #{value.inspect}"
    end
  end
end
