# frozen_string_literal: true

# Bounds how often one caller can spend the SERVER's credential.
#
# A free model is free to the visitor, not to us: gpt-oss on Bedrock bills the
# house key on every call, from an endpoint that is reachable anonymously. An
# unmetered public endpoint backed by a paid key is an open-ended invoice, so
# this is a blunt guard that lands with the first free hosted model — distinct
# from metering (accounting for what was spent), which can follow later.
#
# ONE BUCKET PER CALLER ACROSS ALL FREE MODELS, not per model: the thing being
# protected is a shared wallet, so splitting the budget by model would multiply
# the ceiling by the size of the catalog.
#
# Callers paying with their own key are never throttled — they are not spending
# ours. Ollama models count toward the bucket too: they cost nothing, but one
# caller monopolising the DGX1 queue is its own kind of denial.
module FreeModelThrottle
  Exceeded = Class.new(StandardError)

  LIMIT  = Integer(ENV.fetch("FREE_MODEL_RATE_LIMIT", 15))
  WINDOW = Integer(ENV.fetch("FREE_MODEL_RATE_WINDOW_SECONDS", 300))

  # Raises Exceeded when this caller has used up the window.
  def self.check!(model_id:, llm_api_key:, user: nil, origin: nil, ip: nil)
    return if llm_api_key                                   # paying their own way
    return unless LlmModelMap.free_access_model?(model_id)

    bucket = bucket_for(user:, origin:, ip:)
    count  = bump(bucket)
    return if count <= LIMIT

    raise Exceeded, "Free-model limit reached (#{LIMIT} requests per " \
                    "#{WINDOW / 60} minutes). Add your own API key to continue."
  end

  # A signed-in user gets their own budget so one busy embedding site cannot
  # exhaust everyone's; anonymous callers are grouped by the embedding origin,
  # falling back to IP when a request carries none (curl, same-origin).
  def self.bucket_for(user:, origin:, ip:)
    return "user:#{user.id}" if user

    "origin:#{origin.presence || ip.presence || 'unknown'}"
  end

  def self.bump(bucket)
    key = "free_model_throttle:#{bucket}"
    count = Rails.cache.increment(key, 1, expires_in: WINDOW)
    return count if count

    # Missing key: seed it, then READ BACK. A store that cannot count (the
    # null store, a broken backend) would otherwise make this method return 1
    # forever and the guard would silently protect nothing — the worst failure
    # mode for something standing in front of a paid endpoint. Availability
    # still wins, but never quietly.
    Rails.cache.write(key, 1, expires_in: WINDOW, raw: true)
    if Rails.cache.read(key, raw: true).to_i.zero?
      Rails.logger.error(
        "[FreeModelThrottle] cache store #{Rails.cache.class} cannot count — " \
        "free-model requests are NOT being throttled"
      )
      return 0
    end

    1
  end
end
