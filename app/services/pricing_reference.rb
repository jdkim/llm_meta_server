# frozen_string_literal: true

# Looks model pricing up from public, machine-readable references.
#
# Providers do not publish pricing through their own APIs, which is why the
# catalog's prices were typed in by hand — and why three of them were
# *extrapolated* rather than looked up, then silently under-charged by 3-6x
# (gpt-5.5-pro was 5/40 against an actual 30/180). Third-party aggregators do
# publish it, so there is no reason to guess.
#
# LiteLLM's map is primary: ~3,500 entries, broad provider coverage, and it is
# what a lot of tooling already relies on. OpenRouter is used only to
# corroborate — when both agree the number is very likely right, and when they
# disagree that is exactly when a human should look.
#
# These are third-party sources, so a lookup is a *suggestion* that gets
# recorded with its provenance, never an automatic overwrite of a verified
# price.
class PricingReference
  LITELLM_URL    = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
  OPENROUTER_URL = "https://openrouter.ai/api/v1/models"
  TIMEOUT        = 30
  CACHE_KEY      = "pricing_reference/v2"
  CACHE_TTL      = 6.hours

  class FetchError < StandardError; end

  Quote = Struct.new(:input, :output, :per_image, :released_on, :sources, :agree, keyword_init: true) do
    def image? = per_image.present?

    # Image models bill per generated image, not per token, so they carry a
    # per_image figure instead of input/output.
    def to_pricing(today: Date.today)
      base = image? ? { "per_image" => per_image } : { "input" => input, "output" => output }
      base.merge("reviewed_at" => today.iso8601, "source" => sources.join("+"), "verified" => false)
    end
  end

  class << self
    # Cached as plain hashes, never as Quote structs.
    #
    # Marshalling a Struct into the cache means any change to its members
    # breaks every existing entry with "struct size differs" — which is
    # exactly what happened when per_image and released_on were added. Plain
    # hashes survive that; Quotes are built on read, for the handful of
    # api_ids actually asked about rather than all ~3,900.
    def raw_table(refresh: false)
      Rails.cache.delete(CACHE_KEY) if refresh
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { build_table }
    end

    def for(api_id, refresh: false)
      quote_from(raw_table(refresh: refresh)[api_id.to_s])
    end

    def quote_from(row)
      return nil if row.blank?
      h = row.symbolize_keys
      released = h[:released_on]
      released = (Date.parse(released) rescue nil) if released.is_a?(String)
      Quote.new(input: h[:input], output: h[:output], per_image: h[:per_image],
                released_on: released, sources: Array(h[:sources]), agree: h[:agree] == true)
    end

    # Compares the live catalog against the reference.
    # Returns rows for models where a reference exists, flagging disagreement.
    def compare(refresh: false)
      ref = raw_table(refresh: refresh)
      LlmModel.active.includes(:llm).filter_map do |m|
        next unless m.chargeable?
        quote = quote_from(ref[m.api_id])
        next if quote.nil?

        ours = m.pricing_symbolized

        if m.image?
          # Only comparable when the reference actually quotes per-image.
          next unless quote.image?
          next unless differs?(ours[:per_image], quote.per_image)

          next {
            id: m.id, llm_type: m.llm.family, meta_id: m.name, api_id: m.api_id,
            ours_input: ours[:per_image], ours_output: nil,
            ref_input: quote.per_image, ref_output: nil, per_image: true,
            sources: quote.sources, agree: quote.agree
          }
        end

        next if quote.image?
        next unless differs?(ours[:input], quote.input) || differs?(ours[:output], quote.output)

        {
          id: m.id, llm_type: m.llm.family, meta_id: m.name, api_id: m.api_id,
          ours_input: ours[:input], ours_output: ours[:output],
          ref_input: quote.input, ref_output: quote.output, per_image: false,
          sources: quote.sources, agree: quote.agree
        }
      end
    end

    def differs?(mine, theirs)
      return true if mine.nil? && !theirs.nil?
      return false if theirs.nil?
      (mine.to_f - theirs.to_f).abs > 0.0001
    end

    # Fills in release dates for catalog models that have none. Never
    # overwrites: a date entered by hand outranks an aggregator's guess.
    def backfill_release_dates!
      filled = 0
      ref = raw_table
      LlmModel.where(released_on: nil).includes(:llm).find_each do |m|
        q = quote_from(ref[m.api_id])
        next if q&.released_on.blank?
        m.update_column(:released_on, q.released_on)
        filled += 1
      end
      filled
    end

    private

    def build_table
      lite = fetch_litellm
      orr  = fetch_openrouter
      (lite.keys | orr.keys).to_h do |id|
        l, o = lite[id], orr[id]
        primary = l || o
        sources = [ ("litellm" if l), ("openrouter" if o) ].compact
        agree   = l && o && !differs?(l[:input], o[:input]) && !differs?(l[:output], o[:output])
        released = (o || {})[:released_on]
        [ id, { "input" => primary[:input], "output" => primary[:output],
                "per_image" => primary[:per_image],
                "released_on" => released&.iso8601,
                "sources" => sources, "agree" => agree.present? } ]
      end
    rescue StandardError => e
      raise FetchError, "#{e.class}: #{e.message}"
    end

    # LiteLLM quotes per-token; the catalog stores USD per 1M tokens.
    def fetch_litellm
      body = get(LITELLM_URL)
      JSON.parse(body).each_with_object({}) do |(id, m), acc|
        next unless m.is_a?(Hash)

        # Image generators quote a flat per-image cost; everything else is
        # per-token. Prefer per-image when present — that is what the catalog
        # bills on for `kind: image`.
        if m["output_cost_per_image"].present?
          acc[id] = { per_image: m["output_cost_per_image"].to_f.round(6) }
        elsif m["input_cost_per_token"] && m["output_cost_per_token"]
          acc[id] = { input: (m["input_cost_per_token"].to_f * 1_000_000).round(4),
                      output: (m["output_cost_per_token"].to_f * 1_000_000).round(4) }
        end
      end
    end

    # OpenRouter ids are namespaced (openai/gpt-5); key on the bare model id so
    # they line up with the catalog's api_id.
    def fetch_openrouter
      body = get(OPENROUTER_URL)
      JSON.parse(body).fetch("data", []).each_with_object({}) do |m, acc|
        pricing = m["pricing"] || {}
        prompt, completion = pricing["prompt"], pricing["completion"]
        next if prompt.blank? || completion.blank?
        id = m["id"].to_s.split("/").last
        next if id.blank? || acc.key?(id)
        acc[id] = { input: (prompt.to_f * 1_000_000).round(4),
                    output: (completion.to_f * 1_000_000).round(4),
                    # Providers expose release dates unevenly (Google not at
                    # all), so OpenRouter's `created` is the one field that
                    # covers almost the whole catalog.
                    released_on: (Time.at(m["created"].to_i).utc.to_date if m["created"].present?) }
      end
    end

    def get(url)
      resp = HTTParty.get(url, timeout: TIMEOUT)
      raise FetchError, "#{url} HTTP #{resp.code}" unless resp.success?
      resp.body
    end
  end
end
