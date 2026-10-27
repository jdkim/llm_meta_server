# frozen_string_literal: true

require "openssl"

# Shared house-credential admission. Origin is never a quota identity.
module FreeModelThrottle
  class Exceeded < StandardError
    attr_reader :status, :retry_after
    def initialize(message, status: 429, retry_after: WINDOW)
      @status, @retry_after = status, retry_after
      super(message)
    end
  end
  # 30, not the 15 main carried. main counted per Puma worker and said so: "15
  # here is deliberate: two workers make the intended ~30 per origin per
  # window." Counting in shared storage makes the number exact, so keeping 15
  # would have quietly halved what production allowed. This preserves the
  # effective ceiling; it is the honest spelling of the same policy.
  LIMIT = Integer(ENV.fetch("FREE_MODEL_RATE_LIMIT", 30))
  WINDOW = Integer(ENV.fetch("FREE_MODEL_RATE_WINDOW_SECONDS", 300))
  GLOBAL_LIMIT = Integer(ENV.fetch("FREE_MODEL_GLOBAL_RATE_LIMIT", 120))
  MAX_BUCKETS = 10000
  raise ArgumentError, "Free model limits must be positive" unless [ LIMIT, WINDOW, GLOBAL_LIMIT ].all?(&:positive?)

  def self.check!(model_id:, llm_api_key:, user: nil, origin: nil, ip: nil)
    return if llm_api_key
    return unless LlmModelMap.free_access_model?(model_id)
    now = Time.now.to_f
    bucket = bucket_for(user: user, origin: origin, ip: ip)
    AnonymousUsageState.update_atomically(scope: "house_throttle") do |state|
      rates = state["rates"] ||= {}
      rates.each_value { |times| times.reject! { |t| t <= now - WINDOW } }
      rates.delete_if { |_, times| times.empty? }
      if !rates.key?(bucket) && rates.size >= MAX_BUCKETS
        raise Exceeded.new("House-model admission capacity reached", status: 503)
      end
      global = rates["global"] ||= []
      times = rates[bucket] ||= []
      if times.size >= LIMIT || global.size >= GLOBAL_LIMIT
        retry_after = [ ((times.size >= LIMIT ? times : global).first + WINDOW - now).ceil, 1 ].max
        raise Exceeded.new("Free-model limit reached (#{LIMIT} requests per #{WINDOW / 60} minutes). Add your own API key to continue.", retry_after: retry_after)
      end
      times << now
      global << now
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error "[FreeModelThrottle] admission store unavailable: #{e.class}"
    raise Exceeded.new("House-model admission unavailable", status: 503, retry_after: 30)
  end

  def self.bucket_for(user:, origin:, ip:)
    identity = user ? "user:#{user.id}" : "ip:#{ip.presence || 'unknown'}"
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "house:#{identity}")
  end
end
