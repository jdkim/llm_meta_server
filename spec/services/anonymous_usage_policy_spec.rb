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
    # The allowlist is opt-in now, so this states the narrowing explicitly
    # rather than relying on a default that named one model and therefore
    # decided deployment policy for every operator who never set it.
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("ANONYMOUS_MODELS", "").and_return("qwen3-8-27b-fast")

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
    # Two global slots and one per IP, stated here: the point is that the two
    # ceilings are separate — a second request from one IP is refused for
    # concurrency while a third IP is refused for capacity — not that the
    # deployment currently allows any particular number.
    slots = described_class.new(limits: { llm_global: 2, llm_per_ip: 1 }, clock: -> { now })
    a = slots.acquire!(kind: "llm", ip: "a")
    b = slots.acquire!(kind: "llm", ip: "b")
    expect { slots.acquire!(kind: "llm", ip: "a") }.to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("concurrency") }
    expect { slots.acquire!(kind: "llm", ip: "c") }.to raise_error(described_class::Rejected) { |e| expect(e.status).to eq(503) }
    slots.release!(a)
    expect(slots.acquire!(kind: "llm", ip: "c")).to include(kind: "llm")
    slots.release!(b)
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

  it "charges the elapsed time of a failed operation and keeps no reservation" do
    # This replaces an assertion that the reservation was RETAINED here. What
    # that test protected — that a failure is still paid for — holds: the time
    # spent is charged. What changed is that the slot is not held afterwards,
    # because a failure which arrived as a result is not uncertainty about
    # whether upstream stopped.
    readings = [ now, now + 3 ]
    moving = described_class.new(clock: -> { readings.shift || now + 3 })
    permit = moving.acquire!(kind: "llm", ip: "a")

    expect { moving.run(permit) { raise "upstream failure" } }.to raise_error("upstream failure")

    state = AnonymousUsageState.find_by!(scope: "admission").state
    expect(state["leases"]).to be_empty
    expect(state["daily"].values.sum).to eq(3)
  end

  it "does not put Ollama options on a hosted model's request" do
    # LlmRbFacade#context_window returns a present num_ctx INSTEAD of the
    # model's own window, so injecting one here told the pre-flight check that
    # gpt-oss-120b holds 65536 tokens rather than 128,000 — and refused turns
    # that fit. Correct when anonymous meant Ollama only, wrong once free-access
    # hosted models were admitted.
    settings = policy.validate_llm!(input, model: "gpt-oss-120b", generation: {}, local: false)

    expect(settings[:options]).to be_nil
  end

  it "still supplies Ollama options for a locally served model" do
    settings = policy.validate_llm!(input, model: "qwen3-8-27b-fast", generation: {}, local: true)

    expect(settings[:options]).to include(num_ctx: 65536, num_predict: 4096)
  end

  it "never admits a tool result larger than the message that must carry it back" do
    # 256 KB in and 128 KB out was the shape before: a tool result was accepted
    # on one turn and then rejected as "Message is too large" on the next, so
    # the conversation worked once and then could not continue — failing on a
    # turn where the visitor had changed nothing.
    tight = described_class.new(limits: { message_bytes: 1000, result_bytes: 50000 }, clock: -> { now })

    expect(tight.acquire!(kind: "mcp", ip: "a")[:result_bytes]).to eq(1000)
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

  it "releases the execution slot when the operation fails with an ordinary error" do
    # A provider error ARRIVES as a result, so the call is over. Quarantining
    # it held the slot: with two global slots, two Bedrock 400s or two blank
    # medgemma replies left every anonymous visitor on 503 until an operator
    # ran the rake task — and the state is in Postgres, so a restart did not
    # clear it either.
    limited = described_class.new(limits: { llm_global: 1 }, clock: -> { now })
    permit = limited.acquire!(kind: "llm", ip: "a")

    expect { limited.run(permit) { raise "provider said 400" } }.to raise_error("provider said 400")

    expect { limited.acquire!(kind: "llm", ip: "b") }.not_to raise_error
    expect(AnonymousUsageState.find_by!(scope: "admission").state["leases"]).not_to have_key(permit[:id])
  end

  it "quarantines a cancelled reservation, because upstream may still be running" do
    # The narrow case the quarantine exists for: we stopped waiting, which
    # proves nothing about the GPU or the remote tool.
    limited = described_class.new(limits: { llm_global: 1 }, clock: -> { now })
    permit = limited.acquire!(kind: "llm", ip: "a")

    expect { limited.run(permit) { raise described_class::Stopped, "switched off" } }
      .to raise_error(described_class::Stopped)

    state = AnonymousUsageState.find_by!(scope: "admission").state
    expect(state["leases"][permit[:id]]["uncertain"]).to be(true)
    expect { limited.acquire!(kind: "llm", ip: "b") }
      .to raise_error(described_class::Rejected) { |e| expect(e.code).to eq("capacity") }
  end

  it "does not charge a reconciled reservation twice" do
    permit = policy.acquire!(kind: "llm", ip: "a")
    expect { policy.run(permit) { raise described_class::Stopped, "switched off" } }
      .to raise_error(described_class::Stopped)

    described_class.reconcile!(permit[:id], actor: "spec", reason: "verified upstream stopped")

    state = AnonymousUsageState.find_by!(scope: "admission").state
    expect(state["global_daily"].values.sum { |v| v["seconds"] }).to eq(600)
    expect { described_class.reconcile!(permit[:id], actor: "spec", reason: "duplicate") }
      .to raise_error(ArgumentError)
  end

  it "releases an abandoned reservation after the grace period, charging it in full" do
    # A killed worker leaves a lease behind. An operator who never reads the
    # log must not be the reason a public page stops answering.
    permit = policy.acquire!(kind: "llm", ip: "a")

    later = described_class.new(limits: { abandoned_grace_seconds: 60 }, clock: -> { now + 700 })
    later.acquire!(kind: "mcp", ip: "b")

    state = AnonymousUsageState.find_by!(scope: "admission").state
    expect(state["leases"]).not_to have_key(permit[:id])
    expect(state["daily"].values.sum).to eq(600)
    expect(state["global_daily"].values.sum { |v| v["seconds"] }).to eq(600)
  end

  it "does not reconcile active work or allow unaudited recovery" do
    allow(Time).to receive(:now).and_return(Time.at(now))
    permit = policy.acquire!(kind: "llm", ip: "a")
    expect { described_class.reconcile!(permit[:id], actor: "", reason: "") }.to raise_error(ArgumentError)
    expect { described_class.reconcile!(permit[:id], actor: "spec", reason: "unconfirmed") }.to raise_error(ArgumentError)
  end
end
