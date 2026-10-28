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

RSpec.describe AnonymousTrustedProxies, ".from_env" do
  it "parses an explicitly configured ingress list" do
    proxies, defaulted = described_class.from_env("10.0.0.5, 127.0.0.1/32")

    expect(proxies.map(&:to_s)).to eq([ "10.0.0.5", "127.0.0.1" ])
    expect(defaulted).to be(false)
  end

  it "falls back to loopback, and says so, when the variable is missing" do
    # Without this the list is empty, nothing is trusted, and every visitor
    # behind the local nginx is accounted for as 127.0.0.1 — one shared bucket.
    [ nil, "", "  ", "," ].each do |value|
      proxies, defaulted = described_class.from_env(value)

      expect(proxies.map(&:to_s)).to eq([ "127.0.0.1", "::1" ]), "for #{value.inspect}"
      expect(defaulted).to be(true), "for #{value.inspect}"
    end
  end
end


# The bug this guards against cost a production deploy. config/initializers run
# BEFORE Zeitwerk autoloading, so naming an app/ constant at LOAD TIME in one
# raises NameError at boot. It is invisible to the suite twice over: autoloading
# works in the test environment, and the anonymous initializer's body is gated
# on Rails.env.production?, so no example ever ran it. 1,171 passing examples
# and four green CI jobs sat on top of an app that could not boot.
#
# Parsed rather than grepped: a constant inside a method body or a block (such
# as config.to_prepare, which is the documented place for exactly this) resolves
# later, when autoloading is available. A regex flagged one of those and would
# have trained the next person to ignore this test.
RSpec.describe "config/initializers" do
  def load_time_constants(file)
    names = []
    visit = lambda do |node|
      next unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
      next if [ :DEFN, :DEFS, :ITER ].include?(node.type)

      names << node.children.compact.first.to_s if node.type == :CONST
      node.children.each { |child| visit.call(child) }
    end
    visit.call(RubyVM::AbstractSyntaxTree.parse_file(file))
    names
  end

  it "do not name an autoloaded app/ constant at load time" do
    autoloaded = Dir[Rails.root.join("app/**/*.rb")]
      .map { |file| File.basename(file, ".rb").camelize }
      .reject { |name| name.start_with?("Application") }
      .to_set

    offenders = Dir[Rails.root.join("config/initializers/*.rb")].flat_map do |file|
      load_time_constants(file).select { |name| autoloaded.include?(name) }
                               .map { |name| "#{File.basename(file)} names #{name} at load time" }
    end

    expect(offenders).to be_empty, offenders.join("\n")
  end
end
