require "openssl"
require "securerandom"

# All anonymous entry points share this admission gate across Puma workers.
class AnonymousUsagePolicy
  class Rejected < StandardError
    attr_reader :code, :status, :retry_after
    def initialize(code, message, status: 429, retry_after: nil)
      @code, @status, @retry_after = code, status, retry_after
      super(message)
    end
  end

  # Deliberately outside StandardError: provider/client broad rescue clauses
  # must not swallow cancellation and continue consuming an execution slot.
  class Cancelled < Exception; end
  class DeadlineExceeded < Cancelled; end
  class Stopped < Cancelled; end

  DEFAULTS = {
    # message_bytes is deliberately not smaller than result_bytes: a tool
    # result that was admitted must fit in the message that carries it back on
    # the next turn, or the conversation succeeds once and then cannot continue.
    "body_bytes" => 1048576, "messages" => 80, "message_bytes" => 262144,
    "tools" => 40, "local_tools" => 16, "schema_bytes" => 65536,
    "argument_bytes" => 32768, "num_ctx" => 65536, "num_predict" => 4096,
    "llm_rate" => 30, "mcp_rate" => 60,
    "llm_global" => 4, "llm_per_ip" => 1,
    "mcp_global" => 8, "mcp_per_ip" => 2,
    "llm_seconds" => 600, "mcp_seconds" => 30,
    "global_daily_seconds" => 14400, "llm_daily_calls" => 400, "mcp_daily_calls" => 10000,
    "daily_seconds" => 1800, "result_bytes" => 262144,
    "tracked_ips" => 10000, "abandoned_grace_seconds" => 3600
  }.freeze

  attr_reader :limits

  def initialize(limits: {}, clock: -> { Time.now.to_f })
    @limits = DEFAULTS.dup
    DEFAULTS.each_key do |key|
      @limits[key] = Integer(ENV.fetch("ANONYMOUS_#{key.upcase}", @limits[key]))
      raise ArgumentError, "ANONYMOUS_#{key.upcase} must be positive" unless @limits[key].positive?
    end
    @limits.merge!(limits.stringify_keys)
    raise ArgumentError, "Limits must be positive numbers" unless @limits.values.all? { |v| v.is_a?(Numeric) && v.positive? && v.finite? }
    @clock = clock
  end

  def subject(ip)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "anonymous:#{ip}")
  end

  def validate_llm!(params, model:, generation:, local: true)
    # An OPTIONAL narrowing, empty by default. Defaulting to one model name
    # meant a deployment that never set this served nothing anonymously but
    # that model, which is a policy decision disguised as a default.
    allowed = ENV.fetch("ANONYMOUS_MODELS", "").split(",").map(&:strip).reject(&:blank?)
    invalid!("Model is not available for anonymous use") if allowed.any? && !allowed.include?(model)
    messages = params[:messages]
    invalid!("messages must be a non-empty array") unless messages.is_a?(Array) && messages.any?
    invalid!("Too many messages") if messages.length > limits["messages"]
    messages.each do |message|
      invalid!("Invalid message") unless object?(message)
      invalid!("Invalid message role") unless %w[system user assistant tool].include?(message[:role].to_s)
      invalid!("Message is too large") if message[:content].to_s.bytesize > limits["message_bytes"]
      calls = message[:tool_calls]
      if calls
        invalid!("Invalid tool calls") unless calls.is_a?(Array) && calls.length <= limits["tools"]
        calls.each do |call|
          invalid!("Invalid tool call") unless object?(call)
          validate_arguments!(call[:arguments])
        end
      end
    end
    validate_list!(params[:tool_ids], limits["tools"], "tool_ids")
    validate_list!(params[:local_tools], limits["local_tools"], "local_tools")
    Array(params[:local_tools]).each do |tool|
      invalid!("Invalid local tool") unless object?(tool) && tool[:name].is_a?(String)
      invalid!("Invalid local schema") unless object?(tool[:input_schema]) || object?(tool[:inputSchema])
    end
    invalid!("Local schemas are too large") if params[:local_tools].to_json.bytesize > limits["schema_bytes"]
    settings = generation.deep_stringify_keys
    invalid!("Unknown generation setting") unless (settings.keys - %w[options think temperature top_p]).empty?
    options = settings.fetch("options", {})
    invalid!("options must be an object") unless options.is_a?(Hash)
    invalid!("Unknown Ollama option") unless (options.keys - %w[num_ctx num_predict temperature top_p repeat_penalty seed]).empty?
    integer_range!(options, "num_ctx", 1, limits["num_ctx"])
    integer_range!(options, "num_predict", 1, limits["num_predict"])
    integer_range!(options, "seed", 0, 2147483647)
    [ settings, options ].each do |values|
      number_range!(values, "temperature", 0, 2)
      number_range!(values, "top_p", 0, 1)
    end
    number_range!(options, "repeat_penalty", 0, 2)
    invalid!("think must be boolean") if settings.key?("think") && ![ true, false ].include?(settings["think"])
    # Ollama options go only to models Ollama actually serves. num_ctx is not a
    # harmless extra for a hosted model: LlmRbFacade#context_window treats a
    # present num_ctx as authoritative and returns it INSTEAD of the model's own
    # window, so injecting 65536 would tell the pre-flight check that
    # gpt-oss-120b holds half of its real 128,000 tokens, and turns that fit
    # would be refused. This is where ollama_model? is the right question —
    # where the model runs — as against free_access_model? above, which asks
    # whether a caller key is needed.
    if local
      settings["options"] = options.reverse_merge("num_ctx" => limits["num_ctx"], "num_predict" => limits["num_predict"])
    end
    settings.deep_symbolize_keys
  end

  def validate_arguments!(arguments)
    return if arguments.nil?
    invalid!("arguments must be an object") unless object?(arguments)
    invalid!("Tool arguments are too large") if arguments.to_json.bytesize > limits["argument_bytes"]
  end

  def acquire!(kind:, ip:, tool: nil)
    now = @clock.call
    key = subject(ip)
    rules = tool_rules(tool)
    permit = AnonymousUsageState.update_atomically do |state|
      prepare!(state, now)
      reject_stopped!(state, kind)
      rate_key = "#{kind}:#{key}"
      rates = state["rates"]
      if !rates.key?(rate_key) && rates.size >= limits["tracked_ips"] * 2
        raise Rejected.new("capacity", "Anonymous admission capacity reached", status: 503, retry_after: 60)
      end
      timestamps = rates[rate_key] ||= []
      if timestamps.length >= limits["#{kind}_rate"]
        raise Rejected.new("rate_limit", "Too many anonymous requests", retry_after: [ (timestamps.first + 60 - now).ceil, 1 ].max)
      end
      leases = state["leases"].values
      active = leases.select { |lease| lease["kind"] == kind }
      if active.count { |lease| lease["subject"] == key } >= limits["#{kind}_per_ip"]
        raise Rejected.new("concurrency", "Another anonymous request is already running", retry_after: 5)
      end
      if active.length >= limits["#{kind}_global"]
        raise Rejected.new("capacity", "Anonymous execution slots are busy", status: 503, retry_after: 5)
      end
      tool_key = tool && "#{tool.mcp_server.uuid}:#{tool.name}"
      if tool_key && active.count { |lease| lease["tool"] == tool_key } >= rules["concurrency"]
        raise Rejected.new("tool_busy", "Tool execution slots are busy", status: 503, retry_after: 5)
      end
      if tool_key
        tool_rate_key = "tool:#{tool_key}"
        tool_times = rates[tool_rate_key] ||= []
        if tool_times.length >= rules["rate"]
          raise Rejected.new("tool_rate_limit", "Tool request limit reached", retry_after: [ (tool_times.first + 60 - now).ceil, 1 ].max)
        end
        tool_times << now
      end
      day = Time.at(now).utc.strftime("%Y-%m-%d")
      global_key = "#{day}:#{kind}"
      global_daily = state["global_daily"][global_key] ||= { "calls" => 0, "seconds" => 0 }
      if global_daily["calls"] >= limits["#{kind}_daily_calls"]
        raise Rejected.new("global_daily_budget", "Global anonymous daily request budget exhausted", status: 503, retry_after: 60)
      end
      seconds = kind == "mcp" ? rules["seconds"] : limits["llm_seconds"]
      if kind == "llm"
        total = global_daily["seconds"] + leases.select { |l| l["global_budget"] == global_key }.sum { |l| l["reserved"] }
        seconds = [ seconds, limits["global_daily_seconds"] - total ].min
        if seconds < 1
          raise Rejected.new("global_daily_budget", "Global anonymous daily inference budget exhausted", status: 503, retry_after: 60)
        end
      end
      budget_key = "#{Time.at(now).utc.strftime('%Y-%m-%d')}:#{key}"
      if kind == "llm"
        used = state["daily"].fetch(budget_key, 0)
        reserved = leases.select { |lease| lease["budget"] == budget_key }.sum { |lease| lease["reserved"] }
        seconds = [ seconds, limits["daily_seconds"] - used - reserved ].min
        if seconds < 1
          reset = Time.at(now).utc.to_date.next_day.to_time(:utc).to_f
          raise Rejected.new("daily_budget", "Anonymous daily inference budget exhausted", retry_after: (reset - now).ceil)
        end
      end
      if kind == "llm" && !state["daily"].key?(budget_key) && state["daily"].size >= limits["tracked_ips"] * 3
        raise Rejected.new("capacity", "Anonymous daily accounting capacity reached", status: 503, retry_after: 60)
      end
      state["daily"][budget_key] ||= 0 if kind == "llm"
      global_daily["calls"] += 1
      timestamps << now
      id = SecureRandom.uuid
      lease = { "kind" => kind, "subject" => key, "tool" => tool_key, "started" => now,
                "deadline" => now + seconds, "reserved" => seconds,
                "budget" => kind == "llm" ? budget_key : nil,
                "global_budget" => kind == "llm" ? global_key : nil }
      state["leases"][id] = lease
      { id: id, seconds: seconds, kind: kind, result_bytes: rules["result_bytes"] }
    end
    Rails.logger.info({ event: "anonymous_admitted", id: permit[:id], kind: kind,
      subject: key, seconds: permit[:seconds] }.to_json)
    permit
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error "[AnonymousUsage] admission store unavailable: #{e.class}"
    raise Rejected.new("unavailable", "Anonymous admission service unavailable", status: 503, retry_after: 30)
  end

  def release!(permit)
    return unless permit && !permit[:released]
    now = @clock.call
    settled = AnonymousUsageState.update_atomically do |state|
      lease = state.fetch("leases", {})[permit[:id]]
      next unless lease
      # Closing our socket does not prove upstream generation stopped. Hold
      # uncertain work until an operator verifies upstream termination.
      if permit[:uncertain]
        lease["uncertain"] = true
        next
      end
      state["leases"].delete(permit[:id])
      if lease["budget"]
        charge = [ [ now - lease["started"], 0 ].max, lease["reserved"] ].min
        state["daily"][lease["budget"]] = state["daily"].fetch(lease["budget"], 0) + charge
        if lease["global_budget"]
          state["global_daily"][lease["global_budget"]]["seconds"] += charge
        end
      end
      { event: "anonymous_settled", id: permit[:id], kind: lease["kind"], subject: lease["subject"],
        elapsed_seconds: [ now - lease["started"], 0 ].max, charged_seconds: charge }
    end
    Rails.logger.info(settled.to_json) if settled
    permit[:released] = true
  rescue ActiveRecord::ActiveRecordError => e
    # Do not mask the original result. The reserved budget remains charged
    # and the reservation remains occupied if settlement cannot be persisted.
    Rails.logger.error "[AnonymousUsage] settlement failed: #{e.class}"
  end

  def run(permit, disconnected: -> { false })
    owner = Thread.current
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + permit[:seconds]
    monitor = nil
    Thread.handle_interrupt(Cancelled => :never) do
      begin
        monitor = Thread.new do
          loop do
            sleep 0.25
            error = if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              DeadlineExceeded.new("Anonymous execution time limit reached")
            elsif disconnected.call
              Cancelled.new("Client disconnected")
            elsif !enabled?(permit[:kind])
              Stopped.new("Anonymous execution has been stopped")
            end
            if error
              owner.raise(error)
              break
            end
          end
        rescue ActiveRecord::ActiveRecordError
          owner.raise(Stopped.new("Anonymous admission service unavailable"))
        ensure
          ActiveRecord::Base.connection_pool.release_connection
        end
        Thread.handle_interrupt(Cancelled => :immediate) { yield }
      # Cancellation and shutdown are the cases where upstream work may still
      # be running: we stopped waiting, which says nothing about the GPU or the
      # remote tool. An ordinary failure is different — a provider error, a
      # malformed response, a bug in our own code — because it ARRIVED as a
      # result, so the call is over. Quarantining those too meant two provider
      # errors could exhaust site-wide anonymous capacity until an operator ran
      # a rake task, and the state is in Postgres, so a restart did not clear it.
      rescue Cancelled, SystemExit, Interrupt, SignalException
        permit[:uncertain] = true
        raise
      ensure
        monitor&.kill
        monitor&.join
        release!(permit)
      end
    end
  end

  def enabled?(kind)
    return false if ENV["ANONYMOUS_#{kind.upcase}_ENABLED"] == "false"
    ActiveRecord::Base.connection_pool.with_connection do
      !AnonymousUsageState.where(scope: "admission")
        .where("state -> 'enabled' ->> ? = 'false'", kind).exists?
    end
  end

  def self.set_enabled!(kind, enabled, actor:, reason:)
    raise ArgumentError, "kind must be llm or mcp" unless %w[llm mcp].include?(kind)
    raise ArgumentError, "actor and reason are required" if actor.blank? || reason.blank?
    AnonymousUsageState.update_atomically do |state|
      (state["enabled"] ||= {})[kind] = enabled
      history = state["changes"] ||= []
      history << { "kind" => kind, "enabled" => enabled, "actor" => actor, "reason" => reason, "at" => Time.now.utc.iso8601 }
      state["changes"] = history.last(100)
    end
    Rails.logger.warn({ event: "anonymous_switch", kind: kind, enabled: enabled, actor: actor, reason: reason }.to_json)
  end

  # Operator-only recovery after checking the provider/remote worker stopped.
  # Charge the full reserved time and retain an audit event in shared storage.
  def self.reconcile!(id, actor:, reason:)
    raise ArgumentError, "actor and reason are required" if actor.blank? || reason.blank?
    event = AnonymousUsageState.update_atomically do |state|
      lease = state.fetch("leases", {})[id]
      raise ArgumentError, "Only an uncertain reservation can be reconciled" unless lease && (lease["uncertain"] || lease["deadline"] + 5 < Time.now.to_f)
      if lease["budget"]
        state["daily"][lease["budget"]] = state["daily"].fetch(lease["budget"], 0) + lease["reserved"]
        if lease["global_budget"]
          state["global_daily"][lease["global_budget"]]["seconds"] += lease["reserved"]
        end
      end
      state["leases"].delete(id)
      event = { "event" => "anonymous_reconciled", "id" => id, "actor" => actor, "reason" => reason, "at" => Time.now.utc.iso8601 }
      state["changes"] = ((state["changes"] || []) + [ event ]).last(100)
      event
    end
    Rails.logger.warn(event.to_json)
  end

  private

  def prepare!(state, now)
    state["rates"] ||= {}
    state["daily"] ||= {}
    state["leases"] ||= {}
    state["global_daily"] ||= {}
    state["rates"].each_value { |times| times.reject! { |time| time <= now - 60 } }
    state["rates"].delete_if { |_, times| times.empty? }
    # Never assume an expired HTTP lease proves the GPU/remote tool stopped.
    # Quarantine abandoned work until an operator verifies upstream termination.
    state["leases"].delete_if do |id, lease|
      next false unless lease["deadline"] + 5 < now
      lease["uncertain"] = true
      next false unless lease["deadline"] + limits["abandoned_grace_seconds"] < now
      # Past the grace period the slot is released anyway. An operator who
      # never sees the log must not be the reason a public page stops
      # answering. The whole reservation is charged, which is the conservative
      # reading: assume the work ran to its limit.
      if lease["budget"]
        state["daily"][lease["budget"]] = state["daily"].fetch(lease["budget"], 0) + lease["reserved"]
        if lease["global_budget"]
          bucket = state["global_daily"][lease["global_budget"]] ||= { "calls" => 0, "seconds" => 0 }
          bucket["seconds"] += lease["reserved"]
        end
      end
      Rails.logger.warn({ event: "anonymous_abandoned_released", id: id, kind: lease["kind"],
        subject: lease["subject"], charged_seconds: lease["reserved"] }.to_json)
      true
    end
    oldest = Time.at(now - 172800).utc.strftime("%Y-%m-%d")
    reserved = state["leases"].values
    state["global_daily"].delete_if { |key, _| key.split(":", 2).first < oldest && reserved.none? { |l| l["global_budget"] == key } }
    state["daily"].delete_if { |key, _| key.split(":", 2).first < oldest && reserved.none? { |l| l["budget"] == key } }
  end

  def reject_stopped!(state, kind)
    if ENV["ANONYMOUS_#{kind.upcase}_ENABLED"] == "false" || state.dig("enabled", kind) == false
      raise Rejected.new("stopped", "Anonymous #{kind} requests are disabled", status: 503, retry_after: 60)
    end
  end

  def tool_rules(tool)
    overrides = JSON.parse(ENV.fetch("ANONYMOUS_TOOL_LIMITS", "{}"))
    rule = overrides.fetch(tool&.name, {})
    { "concurrency" => [ Integer(rule.fetch("concurrency", 2)), limits["mcp_global"] ].min,
      "rate" => [ Integer(rule.fetch("rate", limits["mcp_rate"])), limits["mcp_rate"] ].min,
      "seconds" => [ Float(rule.fetch("seconds", limits["mcp_seconds"])), limits["mcp_seconds"] ].min,
      "result_bytes" => [ Integer(rule.fetch("result_bytes", limits["result_bytes"])),
                          limits["result_bytes"], limits["message_bytes"] ].min }.tap do |rules|
      raise ArgumentError, "Tool limits must be positive" unless rules.values.all?(&:positive?)
    end
  end

  def object?(value)
    value.is_a?(Hash) || value.is_a?(ActionController::Parameters)
  end

  def validate_list!(value, max, name)
    invalid!("#{name} must be an array with at most #{max} entries") if value && (!value.is_a?(Array) || value.length > max)
  end

  def integer_range!(values, key, min, max)
    return unless values.key?(key)
    value = values[key]
    invalid!("#{key} must be an integer between #{min} and #{max}") unless value.is_a?(Integer) && value.between?(min, max)
  end

  def number_range!(values, key, min, max)
    return unless values.key?(key)
    value = values[key]
    invalid!("#{key} is outside the allowed range") unless value.is_a?(Numeric) && value.finite? && value.between?(min, max)
  end

  def invalid!(message)
    raise Rejected.new("invalid_input", message, status: 400)
  end
end
