require "rails_helper"

# Separate DB connections must see committed admission and emergency state.
RSpec.describe "Anonymous admission across workers" do
  self.use_transactional_tests = false
  before { AnonymousUsageState.delete_all }
  after { AnonymousUsageState.delete_all }

  it "atomically admits at most the global limit on separate connections" do
    gate = Queue.new
    outcomes = Queue.new
    threads = 4.times.map do |i|
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection do
          outcomes << AnonymousUsagePolicy.new.acquire!(kind: "llm", ip: "worker-#{i}")
        rescue AnonymousUsagePolicy::Rejected => e
          outcomes << e
        end
      end
    end
    4.times { gate << true }
    threads.each(&:join)
    results = 4.times.map { outcomes.pop }
    expect(results.count { |result| result.is_a?(Hash) }).to eq(2)
    expect(results.grep(AnonymousUsagePolicy::Rejected).map(&:status)).to eq([ 503, 503 ])
    expect(AnonymousUsageState.first.state["leases"].size).to eq(2)
  end

  it "interrupts work already running when an operator stops it" do
    policy = AnonymousUsagePolicy.new
    permit = policy.acquire!(kind: "llm", ip: "worker")
    stopper = Thread.new do
      sleep 0.1
      AnonymousUsagePolicy.set_enabled!("llm", false, actor: "spec", reason: "stop running work")
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end
    expect { policy.run(permit) { sleep 10 } }.to raise_error(AnonymousUsagePolicy::Stopped)
    stopper.join
    expect(AnonymousUsageState.first.state["leases"]).to be_empty
  end

  it "interrupts work on client disconnect and releases its reservation" do
    policy = AnonymousUsagePolicy.new
    permit = policy.acquire!(kind: "mcp", ip: "worker")
    expect { policy.run(permit, disconnected: -> { true }) { sleep 10 } }
      .to raise_error(AnonymousUsagePolicy::Cancelled)
    expect(AnonymousUsageState.first.state["leases"]).to be_empty
  end
  it "closes the HTTP socket when a stalled upstream operation is interrupted" do
    require "socket"
    WebMock.disable_net_connect!(allow_localhost: true)
    server = TCPServer.new("127.0.0.1", 0)
    eof = Queue.new
    peer_thread = Thread.new do
      socket = server.accept
      while (line = socket.gets) && line != "\r\n"
        # Consume request headers before waiting for EOF.
      end
      eof << socket.read
    ensure
      socket&.close
    end
    policy = AnonymousUsagePolicy.new
    permit = policy.acquire!(kind: "mcp", ip: "worker")
    permit[:seconds] = 0.05
    expect {
      policy.run(permit) do
        Net::HTTP.start("127.0.0.1", server.addr[1], nil) { |http| http.get("/") }
      end
    }.to raise_error(AnonymousUsagePolicy::DeadlineExceeded)
    expect(peer_thread.join(2)).not_to be_nil
    expect(eof.pop).to eq("")
    expect(AnonymousUsageState.first.state["leases"]).to be_empty
  ensure
    peer_thread&.kill
    server&.close
    WebMock.disable_net_connect!
  end
end
