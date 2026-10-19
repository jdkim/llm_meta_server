require "rails_helper"

RSpec.describe AnonymousUsagePolicy do
  let(:now) { Time.utc(2026, 10, 2, 12).to_f }
  let(:policy) { described_class.new(clock: -> { now }) }
  let(:input) { ActionController::Parameters.new(messages: [ { role: "user", content: "hi" } ]) }
  before { AnonymousUsageState.delete_all }

  it "supplies bounded defaults, preserves the full guide within the content limit" do
    input[:messages] << { role: "tool", content: "g" * 117000 }
    expect(policy.validate_llm!(input, model: "qwen3-8-27b-fast", generation: {})).to include(
      options: { num_ctx: 65536, num_predict: 4096 })
  end

  [ { options: { num_predict: -1 } }, { options: { num_predict: 4097 } },
    { options: { num_ctx: 65537 } }, { options: { num_ctx: "65536" } },
    { options: { num_gpu: 999 } }, { options: [] }, { keep_alive: -1 },
    { temperature: Float::INFINITY }, { think: "true" } ].each do |settings|
    it "rejects unsafe generation settings #{settings}" do
      expect { policy.validate_llm!(input, model: "qwen3-8-27b-fast", generation: settings) }
        .to raise_error(described_class::Rejected)
    end
  end

  it "rejects non-allowlisted models and oversized input collections" do
    expect { policy.validate_llm!(input, model: "other", generation: {}) }.to raise_error(described_class::Rejected)
    input[:messages] = Array.new(81) { { role: "user", content: "hi" } }
    expect { policy.validate_llm!(input, model: "qwen3-8-27b-fast", generation: {}) }.to raise_error(described_class::Rejected)
  end

  it "rejects large arguments and malformed message/tool entries" do
    expect { policy.validate_arguments!(q: "x" * 32768) }.to raise_error(described_class::Rejected)
    expect { policy.validate_arguments!([]) }.to raise_error(described_class::Rejected)
    input[:messages] = [ { role: "user", tool_calls: [ "invalid" ] } ]
    expect { policy.validate_llm!(input, model: "qwen3-8-27b-fast", generation: {}) }.to raise_error(described_class::Rejected)
  end

  it "enforces independent per-IP and global slots" do
    a = policy.acquire!(kind: "llm", ip: "a")
    b = policy.acquire!(kind: "llm", ip: "b")
    expect { policy.acquire!(kind: "llm", ip: "a") }.to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("concurrency") }
    expect { policy.acquire!(kind: "llm", ip: "c") }.to raise_error(described_class::Rejected) { |e| expect(e.status).to eq(503) }
    policy.release!(a)
    expect(policy.acquire!(kind: "llm", ip: "c")).to include(kind: "llm")
    policy.release!(b)
  end

  it "keeps rate counters after successful requests and reopens after the window" do
    policy.limits["llm_rate"].times { policy.release!(policy.acquire!(kind: "llm", ip: "a")) }
    expect { policy.acquire!(kind: "llm", ip: "a") }.to raise_error(described_class::Rejected) { |e| expect(e.retry_after).to eq(60) }
    later = described_class.new(clock: -> { now + 61 })
    expect(later.acquire!(kind: "llm", ip: "a")).to include(kind: "llm")
  end

  it "reserves remaining daily budget and settles elapsed time exactly once" do
    limited = described_class.new(limits: { llm_seconds: 2, daily_seconds: 3 }, clock: -> { now })
    permit = limited.acquire!(kind: "llm", ip: "a")
    finish = described_class.new(limits: { llm_seconds: 2, daily_seconds: 3 }, clock: -> { now + 2 })
    finish.release!(permit)
    finish.release!(permit)
    next_permit = finish.acquire!(kind: "llm", ip: "a")
    expect(next_permit[:seconds]).to eq(1)
    described_class.new(clock: -> { now + 3 }).release!(next_permit)
    expect { described_class.new(limits: { daily_seconds: 3 }, clock: -> { now + 4 }).acquire!(kind: "llm", ip: "a") }
      .to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("daily_budget") }
  end

  it "quarantines expired reservations until upstream termination is confirmed" do
    policy.acquire!(kind: "llm", ip: "a")
    later = described_class.new(limits: { daily_seconds: 600 }, clock: -> { now + 606 })
    expect { later.acquire!(kind: "llm", ip: "a") }.to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("concurrency") }
    expect(later.acquire!(kind: "llm", ip: "b")).to include(kind: "llm")
  end

  it "bounds execution and retains the reservation until verified operator recovery" do
    permit = policy.acquire!(kind: "llm", ip: "a")
    permit[:seconds] = 0.02
    expect { policy.run(permit) { sleep 10 } }.to raise_error(described_class::DeadlineExceeded)
    expect(AnonymousUsageState.find_by!(scope: "admission").state["leases"]).not_to be_empty
  end

  it "retains a conservative reservation when its operation raises" do
    permit = policy.acquire!(kind: "llm", ip: "a")
    expect { policy.run(permit) { raise "upstream failure" } }.to raise_error("upstream failure")
    expect(AnonymousUsageState.find_by!(scope: "admission").state["leases"]).not_to be_empty
  end

  it "supports independent audited stop switches and restart" do
    described_class.set_enabled!("llm", false, actor: "operator", reason: "load")
    expect { policy.acquire!(kind: "llm", ip: "a") }.to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("stopped") }
    expect(policy.acquire!(kind: "mcp", ip: "a")).to include(kind: "mcp")
    described_class.set_enabled!("llm", true, actor: "operator", reason: "recovered")
    expect(policy.acquire!(kind: "llm", ip: "a")).to include(kind: "llm")
    expect(AnonymousUsageState.first.state["changes"].last).to include("actor" => "operator", "reason" => "recovered")
  end

  it "fails closed when the shared store is unavailable" do
    allow(AnonymousUsageState).to receive(:update_atomically).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect { policy.acquire!(kind: "llm", ip: "a") }.to raise_error(described_class::Rejected) { |e| expect(e.status).to eq(503) }
  end
  it "enforces shared per-tool rate, concurrency and stricter configured limits" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("ANONYMOUS_TOOL_LIMITS", "{}").and_return(
      '{"guide":{"concurrency":1,"rate":1,"seconds":5,"result_bytes":120000}}')
    tool = Struct.new(:name, :mcp_server).new("guide", Struct.new(:uuid).new("server"))
    permit = policy.acquire!(kind: "mcp", ip: "a", tool: tool)
    expect(permit).to include(seconds: 5, result_bytes: 120000)
    expect { policy.acquire!(kind: "mcp", ip: "b", tool: tool) }
      .to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("tool_busy") }
    policy.release!(permit)
    expect { policy.acquire!(kind: "mcp", ip: "b", tool: tool) }
      .to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("tool_rate_limit") }
  end

  it "resets the per-IP inference budget at UTC midnight" do
    budget = described_class.new(limits: { daily_seconds: 1 }, clock: -> { now })
    permit = budget.acquire!(kind: "llm", ip: "a")
    described_class.new(clock: -> { now + 1 }).release!(permit)
    tomorrow = described_class.new(limits: { daily_seconds: 1 }, clock: -> { now + 86400 })
    expect(tomorrow.acquire!(kind: "llm", ip: "a")).to include(seconds: 1)
  end
  it "enforces a global daily request budget across rotating IPs" do
    capped = described_class.new(limits: { llm_daily_calls: 2 }, clock: -> { now })
    %w[a b].each { |ip| capped.release!(capped.acquire!(kind: "llm", ip: ip)) }
    expect { capped.acquire!(kind: "llm", ip: "c") }.to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("global_daily_budget") }
  end

  it "atomically reserves global daily inference time across IPs" do
    capped = described_class.new(limits: { global_daily_seconds: 3, llm_seconds: 2 }, clock: -> { now })
    a = capped.acquire!(kind: "llm", ip: "a")
    b = capped.acquire!(kind: "llm", ip: "b")
    expect(a[:seconds]).to eq(2)
    expect(b[:seconds]).to eq(1)
    capped.run(a) { true }
    expect(capped.acquire!(kind: "llm", ip: "c")[:seconds]).to eq(2)
  end

  it "does not charge an aborted reservation twice when its deadline expires" do
    permit = policy.acquire!(kind: "llm", ip: "a")
    expect { policy.run(permit) { raise "failed" } }.to raise_error("failed")
    policy.release!(permit)
    later = described_class.new(clock: -> { now + 606 })
    later.acquire!(kind: "mcp", ip: "b")
    state = AnonymousUsageState.find_by!(scope: "admission").state
    expect(state["leases"][permit[:id]]["uncertain"]).to be(true)
    described_class.reconcile!(permit[:id], actor: "spec", reason: "verified upstream stopped")
    state = AnonymousUsageState.find_by!(scope: "admission").state
    expect(state["global_daily"].values.sum { |v| v["seconds"] }).to eq(600)
    expect { described_class.reconcile!(permit[:id], actor: "spec", reason: "duplicate") }.to raise_error(ArgumentError)
  end

  it "does not reconcile active work or allow unaudited recovery" do
    allow(Time).to receive(:now).and_return(Time.at(now))
    permit = policy.acquire!(kind: "llm", ip: "a")
    expect { described_class.reconcile!(permit[:id], actor: "", reason: "") }.to raise_error(ArgumentError)
    expect { described_class.reconcile!(permit[:id], actor: "spec", reason: "unconfirmed") }.to raise_error(ArgumentError)
  end

end
