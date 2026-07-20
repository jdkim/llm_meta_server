class ProviderModelIndex
  # Fetches the list of models from each provider's public list-models endpoint,
  # filters to the "frontier chat" subset (excludes embeddings, audio, TTS,
  # fine-tuned variants, etc.), and optionally drops anything older than
  # `min_created`. Returns [{id: <string>, created_at: <Date or nil>}, ...].
  #
  # Used by the `models:check_updates` rake task to help operators decide
  # which new models to add to config/llm_models.yml.

  DEFAULT_LOOKBACK_MONTHS = 12
  HTTP_TIMEOUT_SECONDS    = 20

  class FetchError < StandardError; end

  class << self
    def openai(api_key, min_created: default_min_created, include_dated: false)
      resp = HTTParty.get("https://api.openai.com/v1/models",
        headers: { "Authorization" => "Bearer #{api_key}" }, timeout: HTTP_TIMEOUT_SECONDS)
      raise FetchError, "openai list-models HTTP #{resp.code}" unless resp.success?

      models = JSON.parse(resp.body).fetch("data", [])
      filtered = models
        .map { |m| { id: m["id"].to_s, created_at: unix_to_date(m["created"]) } }
        .select { |m| openai_frontier?(m[:id]) }
        .select { |m| include_dated || !dated_snapshot?(m[:id]) }
        .select { |m| fresh?(m[:created_at], min_created) }
      filtered = drop_redundant_previews(filtered) unless include_dated
      filtered.sort_by { |m| m[:created_at] || Date.new(1970) }.reverse
    end

    def anthropic(api_key, min_created: default_min_created, include_dated: false)
      resp = HTTParty.get("https://api.anthropic.com/v1/models",
        headers: {
          "x-api-key" => api_key,
          "anthropic-version" => "2023-06-01"
        }, timeout: HTTP_TIMEOUT_SECONDS)
      raise FetchError, "anthropic list-models HTTP #{resp.code}" unless resp.success?

      models = JSON.parse(resp.body).fetch("data", [])
      filtered = models
        .map { |m| { id: m["id"].to_s, created_at: parse_iso8601(m["created_at"]) } }
        .select { |m| anthropic_frontier?(m[:id]) }
        .select { |m| include_dated || !dated_snapshot?(m[:id]) }
        .select { |m| fresh?(m[:created_at], min_created) }
      filtered = drop_redundant_previews(filtered) unless include_dated
      filtered.sort_by { |m| m[:created_at] || Date.new(1970) }.reverse
    end

    def google(api_key, min_created: default_min_created, include_dated: false)
      resp = HTTParty.get("https://generativelanguage.googleapis.com/v1beta/models",
        query: { key: api_key }, timeout: HTTP_TIMEOUT_SECONDS)
      raise FetchError, "google list-models HTTP #{resp.code}" unless resp.success?

      models = JSON.parse(resp.body).fetch("models", [])
      # Google's `name` looks like "models/gemini-2.5-pro"; strip the prefix.
      # Google's response doesn't include a created_at field, so freshness
      # filtering is a no-op (all entries have nil created_at and pass).
      filtered = models
        .map { |m| { id: m["name"].to_s.sub(%r{\Amodels/}, ""), created_at: nil } }
        .select { |m| google_frontier?(m[:id]) }
        .select { |m| include_dated || !dated_snapshot?(m[:id]) }
        .select { |m| fresh?(m[:created_at], min_created) }
      filtered = drop_redundant_previews(filtered) unless include_dated
      filtered.sort_by { |m| m[:id] }
    end

    private

    def default_min_created
      Date.today.prev_month(DEFAULT_LOOKBACK_MONTHS)
    end

    # OpenAI: keep chat-capable frontier families; drop embeddings, audio,
    # image gen, moderation, transcription, fine-tuned variants, and legacy
    # <=4 families (rarely worth surfacing as "new").
    def openai_frontier?(id)
      return false if id =~ /-ft-|:ft:/i          # fine-tuned variants
      return false if id =~ /embedding|whisper|tts|dall-e|davinci|babbage|moderation|realtime-preview|audio-preview|search|transcribe|codex/i
      id =~ /\Agpt-[5-9]|\Ao[0-9]|\Achatgpt-/     # gpt-5+, o-series, chatgpt-*
    end

    # Anthropic ships only Claude chat models today; all qualify.
    def anthropic_frontier?(id)
      id.start_with?("claude-")
    end

    # Google: gemini-* chat models. Drop non-chat families: embeddings, QA,
    # tuning API, image gen (imagen), video gen (veo), audio (native-audio/tts),
    # robotics-specialized SKUs (gemini-robotics-*), and developer-eval
    # variants (gemini-*-customtools).
    def google_frontier?(id)
      return false if id =~ /embedding|aqa|tuned|imagen|veo|native-audio|tts|text-embedding|robotics|customtools/i
      id.start_with?("gemini-")
    end

    def fresh?(created_at, min_created)
      return true if created_at.nil? || min_created.nil?
      created_at >= min_created
    end

    # When a `foo-preview` model exists alongside its GA sibling `foo`, the
    # preview identifier is a pin — same relationship as OpenAI's dated
    # snapshots. Drop the preview to avoid duplicate "new candidate" noise.
    # Keeps unique previews (where no GA sibling exists) intact.
    def drop_redundant_previews(models)
      ids = models.map { |m| m[:id] }.to_set
      models.reject { |m| m[:id].end_with?("-preview") && ids.include?(m[:id].sub(/-preview\z/, "")) }
    end

    # True if the id ends with a date-like or version-pin suffix — provider
    # "pin" IDs published alongside the canonical name for reproducibility.
    # They clutter a "what's new?" survey without adding capabilities.
    #
    # Covers: -YYYY-MM-DD (OpenAI), -MM-DD (Gemini preview),
    #         -MMDD (Gemini exp), -YYYYMMDD (Anthropic snapshots),
    #         -NNN (Google numeric version pins like -001, -002).
    def dated_snapshot?(id)
      id =~ /-\d{4}-\d{2}-\d{2}\z/ ||
        id =~ /-\d{2}-\d{2}\z/ ||
        id =~ /-\d{4}\z/ ||
        id =~ /-\d{8}\z/ ||
        id =~ /-\d{3}\z/
    end

    def unix_to_date(ts)
      return nil if ts.nil?
      Time.at(ts.to_i).utc.to_date
    end

    def parse_iso8601(str)
      return nil if str.to_s.empty?
      Date.parse(str.to_s)
    rescue ArgumentError
      nil
    end
  end
end
