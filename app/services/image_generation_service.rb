require "net/http"
require "uri"
require "json"
require "base64"
require "tempfile"

# Generates an image from a text prompt and returns Markdown that embeds the
# image inline as a data URI. Supports Google's Gemini image models and OpenAI's
# gpt-image-* family.
class ImageGenerationService
  GOOGLE_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
  OPENAI_BASE_URL = "https://api.openai.com/v1"
  REQUEST_TIMEOUT_SECONDS = 300

  class << self
    def generate!(model_id:, prompt:, llm_api_key:, image_context: [], image: nil)
      api_key = llm_api_key&.encryptable_api_key&.plain_api_key
      case llm_api_key&.llm_type
      when "google"
        generate_with_google(model_id: model_id, prompt: prompt, api_key: api_key, image_context: image_context, image: image)
      when "openai"
        generate_with_openai(model_id: model_id, prompt: prompt, api_key: api_key, image_context: image_context, image: image)
      else
        raise ArgumentError, "Image generation is not supported for provider: #{llm_api_key&.llm_type.inspect}"
      end
    end

    private

    # OpenAI: text→image via /v1/images/generations, image→image (with prompt
    # as the edit instruction) via /v1/images/edits. Both return
    # { data: [{ b64_json: "..." }] } — gpt-image-1 always uses base64.
    #
    # image_context/image parity with the Google branch: if the user attached
    # a fresh image (`image`) OR any prior assistant turn generated an image
    # (via image_context), we route to /edits with that image as input. This
    # gives the same "keep refining the same image" workflow Nano Banana has.
    def generate_with_openai(model_id:, prompt:, api_key:, image_context: [], image: nil)
      active_image = resolve_active_image(image: image, image_context: image_context)

      if active_image
        generate_openai_edit(model_id: model_id, prompt: prompt, api_key: api_key, active_image: active_image)
      else
        generate_openai_txt2img(model_id: model_id, prompt: prompt, api_key: api_key)
      end
    end

    def generate_openai_txt2img(model_id:, prompt:, api_key:)
      uri = URI("#{OPENAI_BASE_URL}/images/generations")
      req = Net::HTTP::Post.new(uri,
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{api_key}")
      req.body = { model: model_id, prompt: prompt.to_s, n: 1, size: "1024x1024" }.to_json
      dispatch_openai(uri, req)
    end

    # /v1/images/edits expects multipart/form-data. gpt-image-1 accepts PNG
    # (and, per OpenAI docs, WebP + JPEG for gpt-image-1). We pass the mime
    # verbatim; OpenAI rejects unsupported types with a 400 that surfaces up.
    def generate_openai_edit(model_id:, prompt:, api_key:, active_image:)
      uri = URI("#{OPENAI_BASE_URL}/images/edits")
      mime = active_image[:mime] || active_image["mime"] || "image/png"
      bin  = Base64.decode64(active_image[:data_b64] || active_image["data_b64"] || "")
      ext  = mime.split("/").last

      Tempfile.create([ "image-edit", ".#{ext}" ]) do |f|
        f.binmode
        f.write(bin)
        f.rewind

        req = Net::HTTP::Post.new(uri, "Authorization" => "Bearer #{api_key}")
        req.set_form(
          [
            [ "model",  model_id ],
            [ "prompt", prompt.to_s ],
            [ "n",      "1" ],
            [ "size",   "1024x1024" ],
            [ "image",  f, { filename: "input.#{ext}", content_type: mime } ]
          ],
          "multipart/form-data"
        )
        return dispatch_openai(uri, req)
      end
    end

    def dispatch_openai(uri, req)
      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: REQUEST_TIMEOUT_SECONDS) do |http|
        http.request(req)
      end

      unless res.is_a?(Net::HTTPSuccess)
        body = JSON.parse(res.body) rescue nil
        message = body&.dig("error", "message") || res.message
        raise "OpenAI API #{res.code}: #{message}"
      end

      parsed = JSON.parse(res.body)
      data = parsed.dig("data", 0, "b64_json")
      raise "OpenAI returned no image data" if data.to_s.empty?

      "![](data:image/png;base64,#{data})"
    end

    # Shared with the Google branch's logic: fresh `image` wins; otherwise
    # walk `image_context` backwards for the most recent image-bearing turn.
    # Returns { mime:, data_b64: } or nil.
    def resolve_active_image(image:, image_context:)
      if image
        mime = image[:mime] || image["mime"]
        data = image[:data_b64] || image["data_b64"]
        return { mime: mime, data_b64: data } if mime && data
      end

      Array(image_context).reverse_each do |turn|
        m = turn[:response].to_s.match(IMAGE_MD)
        next unless m
        return { mime: m[1], data_b64: m[2] }
      end
      nil
    end

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
