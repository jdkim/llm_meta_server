require "net/http"
require "uri"
require "json"

# Generates an image from a text prompt and returns Markdown that embeds the
# image inline as a data URI. v1 only supports Google's Gemini image models.
class ImageGenerationService
  GOOGLE_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
  REQUEST_TIMEOUT_SECONDS = 300

  class << self
    def generate!(model_id:, prompt:, llm_api_key:, image_context: [], image: nil)
      case llm_api_key&.llm_type
      when "google"
        api_key = llm_api_key.encryptable_api_key.plain_api_key
        generate_with_google(model_id: model_id, prompt: prompt, api_key: api_key, image_context: image_context, image: image)
      else
        raise ArgumentError, "Image generation is not supported for provider: #{llm_api_key&.llm_type.inspect}"
      end
    end

    private

    def generate_with_google(model_id:, prompt:, api_key:, image_context: [], image: nil)
      uri = URI("#{GOOGLE_BASE_URL}/models/#{model_id}:generateContent?key=#{api_key}")
      req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      req.body = {
        contents: build_contents(prompt: prompt, image_context: image_context, image: image),
        generationConfig: { responseModalities: %w[IMAGE TEXT] }
      }.to_json

      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: REQUEST_TIMEOUT_SECONDS) do |http|
        http.request(req)
      end

      unless res.is_a?(Net::HTTPSuccess)
        body = JSON.parse(res.body) rescue nil
        message = body&.dig("error", "message") || res.message
        raise "Google API #{res.code}: #{message}"
      end

      parsed = JSON.parse(res.body)
      candidate = parsed.dig("candidates", 0)
      parts = candidate&.dig("content", "parts") || []

      image_part = parts.find { |p| p["inlineData"] || p["inline_data"] }
      text = parts.filter_map { |p| p["text"]&.strip }.reject(&:empty?).join("\n\n")

      if image_part
        inline = image_part["inlineData"] || image_part["inline_data"]
        mime = inline["mimeType"] || inline["mime_type"] || "image/png"
        data = inline["data"]
        image_md = "![](data:#{mime};base64,#{data})"
        text.present? ? "#{text}\n\n#{image_md}" : image_md
      elsif text.present?
        # Gemini answered with text (clarification, refusal, etc.) — surface it
        # instead of failing so the user sees why no image came back.
        text
      else
        reason = candidate&.dig("finishReason") || parsed.dig("promptFeedback", "blockReason")
        raise "Gemini returned no image#{reason ? " (#{reason})" : ""}"
      end
    end

    IMAGE_MD = /!\[[^\]]*\]\(data:([^;]+);base64,([^\)]+)\)/

    # Build a single user-turn request containing the latest image + the new
    # instruction. We deliberately do NOT replay prior model turns: Gemini's
    # thinking-enabled image models (Nano Banana 2 / Pro) require each
    # replayed model part to carry the original response's `thoughtSignature`,
    # and we don't persist those — so we'd 400 with "Image part is missing a
    # thought_signature". Presenting the prior image as part of the current
    # user turn sidesteps that entirely and works uniformly across the whole
    # Nano Banana family. Trade-off: the model doesn't see the *text* of
    # prior turns, only the latest image + current prompt — adequate for
    # refinement (the visual state is in the image itself).
    def build_contents(prompt:, image_context:, image: nil)
      turns = Array(image_context)

      # User's freshly-attached image takes precedence; otherwise carry
      # forward the most recent image-bearing prior response.
      active_image = image
      if active_image.blank?
        turns.reverse_each do |turn|
          m = turn[:response].to_s.match(IMAGE_MD)
          next unless m
          active_image = { mime: m[1], data_b64: m[2] }
          break
        end
      end

      parts = []
      if active_image
        mime = active_image[:mime] || active_image["mime"]
        data = active_image[:data_b64] || active_image["data_b64"]
        parts << { inlineData: { mimeType: mime, data: data } } if mime && data
      end
      parts << { text: prompt.to_s }
      [ { role: "user", parts: parts } ]
    end

    # Pull `inlineData` parts out of an assistant message that may contain
    # a markdown data-URI image plus optional caption text. When keep_image is
    # false, the image is dropped and only the surrounding text is kept.
    def parse_assistant_parts(response, keep_image: true)
      parts = []
      remaining = response.dup
      while (m = remaining.match(IMAGE_MD))
        preceding = remaining[0...m.begin(0)].strip
        parts << { text: preceding } if preceding.present?
        parts << { inlineData: { mimeType: m[1], data: m[2] } } if keep_image
        remaining = remaining[m.end(0)..] || ""
      end
      trailing = remaining.strip
      parts << { text: trailing } if trailing.present?
      parts
    end
  end
end
