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
    "body_bytes" => 262144, "messages" => 20, "message_bytes" => 131072,
    "tools" => 40, "local_tools" => 16, "schema_bytes" => 65536,
    "argument_bytes" => 32768, "num_ctx" => 65536, "num_predict" => 4096,
    "llm_rate" => 6, "mcp_rate" => 20,
    "llm_global" => 2, "llm_per_ip" => 1,
    "mcp_global" => 8, "mcp_per_ip" => 2,
    "llm_seconds" => 600, "mcp_seconds" => 30,
    "daily_seconds" => 1800, "result_bytes" => 262144,
    "tracked_ips" => 10000
  }.freeze

  attr_reader :limits

  def initialize(limits: {}, clock: -> { Time.now.to_f })
    @limits = DEFAULTS.dup
    DEFAULTS.each_key do |key|
      @limits[key] = Integer(ENV.fetch("ANONYMOUS_#{key.upcase}", @limits[key]))
      raise ArgumentError, "ANONYMOUS_#{key.upcase} must be positive" unless @limits[key].positive?
    end
    @limits.merge!(limits.stringify_keys)
    @clock = clock
  end

  def subject(ip)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "anonymous:#{ip}")
  end

  def validate_llm!(params, model:, generation:)
    allowed = ENV.fetch("ANONYMOUS_MODELS", "glm-4-7-flash").split(",").map(&:strip)
    invalid!("Model is not available for anonymous use") unless allowed.include?(model)
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
    settings["options"] = options.reverse_merge("num_ctx" => limits["num_ctx"], "num_predict" => limits["num_predict"])
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
      seconds = kind == "mcp" ? rules["seconds"] : limits["llm_seconds"]
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
      timestamps << now
      id = SecureRandom.uuid
      lease = { "kind" => kind, "subject" => key, "tool" => tool_key, "started" => now,
                "deadline" => now + seconds, "reserved" => seconds,
                "budget" => kind == "llm" ? budget_key : nil }
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
      lease = state.fetch("leases", {}).delete(permit[:id])
      next unless lease
      if lease["budget"]
        charge = [ [ now - lease["started"], 0 ].max, lease["reserved"] ].min
        state["daily"][lease["budget"]] = state["daily"].fetch(lease["budget"], 0) + charge
      end
      { event: "anonymous_settled", id: permit[:id], kind: lease["kind"], subject: lease["subject"],
        elapsed_seconds: [ now - lease["started"], 0 ].max, charged_seconds: charge }
    end
    Rails.logger.info(settled.to_json) if settled
    permit[:released] = true
  rescue ActiveRecord::ActiveRecordError => e
    # Do not mask the original result. The reserved budget remains charged
    # and the bounded lease expires if settlement cannot be persisted.
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

  private

  def prepare!(state, now)
    state["rates"] ||= {}
    state["daily"] ||= {}
    state["leases"] ||= {}
    state["rates"].each_value { |times| times.reject! { |time| time <= now - 60 } }
    state["rates"].delete_if { |_, times| times.empty? }
    state["leases"].delete_if do |_, lease|
      expired = lease["deadline"] + 5 < now
      if expired && lease["budget"]
        state["daily"][lease["budget"]] = state["daily"].fetch(lease["budget"], 0) + lease["reserved"]
      end
      expired
    end
    oldest = Time.at(now - 172800).utc.strftime("%Y-%m-%d")
    state["daily"].delete_if { |key, _| key.split(":", 2).first < oldest }
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
      "result_bytes" => [ Integer(rule.fetch("result_bytes", limits["result_bytes"])), limits["result_bytes"] ].min }.tap do |rules|
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
