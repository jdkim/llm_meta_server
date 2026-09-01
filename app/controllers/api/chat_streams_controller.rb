class Api::ChatStreamsController < ApiController
  include ActionController::Live

  wrap_parameters false

  def create
    uuid, model_name, prompt = expected_params

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    sink = SseWriter.new(response.stream)
    on_tool_calls = ->(tool_calls) { sink.event("tool_calls", { tool_calls: tool_calls }) }
    on_phase_change = ->(name) { sink.phase(name) }

    # Tell the UI we've started — without this the bubble shows nothing while
    # turn 1 (tool selection, model thinking) is in progress. Keepalive thread
    # also keeps the connection warm through proxies and proves liveness.
    sink.phase("thinking")
    heartbeat = start_heartbeat(sink)

    image = image_param
    images = images_param
    document = document_param

    has_image = image.present? || images.any?
    has_multimodal_input = has_image || document.present?

    if bearer_token
      llm_api_key = current_user.find_llm_api_key uuid
      model_id = LlmModelMap.fetch! model_name, llm_type: llm_api_key&.llm_type
      if has_multimodal_input && !LlmModelMap.supports_vision?(model_name, llm_type: llm_api_key&.llm_type)
        raise ArgumentError, "Selected model doesn't support image or document input"
      end
      if document.present? && !DOCUMENT_CAPABLE_LLM_TYPES.include?(llm_api_key&.llm_type)
        raise ArgumentError, "Document (PDF) attachments are only supported for Anthropic and Gemini models"
      end
      if LlmModelMap.image_model?(model_name, llm_type: llm_api_key&.llm_type)
        markdown = ImageGenerationService.generate!(
          model_id: model_id, prompt: prompt, llm_api_key: llm_api_key,
          image_context: image_context_param,
          image: image || images.last
        )
        sink << markdown
      else
        LlmRbFacade.stream! model_id, prompt,
          sink: sink,
          llm_api_key: llm_api_key,
          tools: selected_tools,
          generation_params: effective_generation_params(model_name, llm_api_key&.llm_type),
          images: images.presence,
          image: image,
          document: document,
          messages: messages_param,
          on_tool_calls: on_tool_calls,
          on_phase_change: on_phase_change,
          endpoint: LlmModelMap.endpoint_for(model_name, llm_type: llm_api_key&.llm_type)
      end
    else
      model_id = LlmModelMap.fetch! model_name
      if has_multimodal_input && !LlmModelMap.supports_vision?(model_name, llm_type: nil)
        raise ArgumentError, "Selected model doesn't support image or document input"
      end
      # Anonymous path is Ollama-only; llm.rb's Ollama adapter rejects
      # non-image local files, so a PDF here would blow up mid-stream.
      if document.present?
        raise ArgumentError, "Document (PDF) attachments are only supported for Anthropic and Gemini models"
      end
      LlmRbFacade.stream! model_id, prompt,
        sink: sink,
        tools: selected_tools,
        generation_params: effective_generation_params(model_name, nil),
        images: images.presence,
        image: image,
        document: document,
        messages: messages_param,
        on_tool_calls: on_tool_calls,
        on_phase_change: on_phase_change,
        endpoint: LlmModelMap.endpoint_for(model_name)
    end

    sink.event("done")
  rescue ActionController::Live::ClientDisconnected
    Rails.logger.info "[ChatStreams] client disconnected mid-stream"
  rescue LLM::RateLimitError => e
    safe_emit_error(sink, "rate_limit", e.message)
  rescue LlmApiKeyRequiredError => e
    safe_emit_error(sink, "api_key_required", e.message)
  rescue ArgumentError => e
    safe_emit_error(sink, "argument_error", e.message)
  rescue ModelNotFoundError => e
    safe_emit_error(sink, "model_not_found", e.message)
  rescue Net::ReadTimeout, Net::OpenTimeout, Timeout::Error => e
    # Dedicated bucket so clients can distinguish an upstream stall (retry
    # with backoff) from a server crash (internal_error). Provider read
    # ceiling is PROVIDER_READ_TIMEOUT_SECONDS in LlmRbFacade.
    #
    # Blame is intentionally ambiguous: this rescue fires for both the LLM
    # provider call AND any MCP tool call that leaks a Timeout past
    # McpClient's own rescue. Naming only the model would be wrong when the
    # stall came from the tool side.
    Rails.logger.warn "[ChatStreams] upstream timeout: #{e.class}: #{e.message}"
    safe_emit_error(sink, "timeout",
                    "An upstream call didn't respond within #{LlmRbFacade.singleton_class::PROVIDER_READ_TIMEOUT_SECONDS} seconds — " \
                    "this could be the model (#{model_name.presence || 'unknown'}) or an MCP tool it invoked. " \
                    "Try again in a moment, or try a smaller/faster model or a shorter prompt.")
  rescue McpClient::McpConnectionError => e
    # A tool the model called failed at the transport layer (HTTP timeout,
    # DNS, HTTP 5xx from the MCP server). Distinct from the LLM path so the
    # user knows to retry or drop the tool, not switch models.
    Rails.logger.warn "[ChatStreams] MCP unavailable: #{e.class}: #{e.message}"
    safe_emit_error(sink, "mcp_unavailable",
                    "An MCP tool the model called is currently unavailable (#{e.message}). " \
                    "It may be slow or offline — try again in a moment, or unselect the tool and retry.")
  rescue McpClient::McpProtocolError => e
    # The MCP server responded but with a malformed / JSON-RPC-error payload.
    Rails.logger.warn "[ChatStreams] MCP protocol error: #{e.class}: #{e.message}"
    safe_emit_error(sink, "mcp_protocol_error",
                    "An MCP tool the model called returned an invalid response (#{e.message}).")
  rescue => e
    Rails.logger.error "[ChatStreams] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    safe_emit_error(sink, "internal_error", e.message)
  ensure
    heartbeat&.kill
    response.stream.close
  end

  private

  def safe_emit_error(sink, code, message)
    sink.event("error", { code: code, message: message })
  rescue IOError, ActionController::Live::ClientDisconnected
    # Stream already closed; nothing to do.
  end

  # Background thread that emits an SSE comment line every 5s. Keeps the
  # connection warm during synchronous waits (tool selection turn, tool
  # execution) so proxies don't time out and the client knows we're alive.
  def start_heartbeat(sink)
    Thread.new do
      loop do
        sleep 5
        begin
          sink.heartbeat
        rescue IOError, ActionController::Live::ClientDisconnected, StandardError
          break
        end
      end
    end
  end

  def expected_params
    params.permit(:llm_api_key_uuid, :model_name, :prompt, tool_ids: [])
    params.expect(:llm_api_key_uuid, :model_name, :prompt)
  end

  def selected_tools
    tool_ids = params.permit(tool_ids: [])[:tool_ids]
    return [] if tool_ids.blank?

    # bearer-guard: `current_user` in ApiController raises "Token is missing"
    # when the request carries no bearer, so on the anon branch pass nil —
    # which routes McpTool.lookup through McpServer.visible_to(nil) and
    # correctly restricts to public_to_anonymous servers.
    viewer = bearer_token.present? ? current_user : nil
    McpToolAdapter.to_llm_functions(McpTool.lookup(tool_ids, viewer: viewer), caller_ip: request.remote_ip)
  end

  # Pass-through: caller sends `generation_settings: {…}` (any keys/values).
  # See Api::ChatsController for rationale.
  def generation_params
    raw = params[:generation_settings]
    return {} if raw.blank?
    hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    hash.deep_symbolize_keys
  end

  # Per-request generation_params layered over per-model defaults from the
  # catalog. Per-request values win at the deepest key. Uses `deep_merge` —
  # a shallow merge would silently drop the catalog's `options.num_ctx`
  # (the Ollama context-window override) the moment a user tweaks any
  # other option like `options.temperature`, reverting Ollama to its 2048
  # default and re-triggering the front-truncation / babble bug.
  def effective_generation_params(model_name, llm_type)
    LlmModelMap.defaults_for(model_name, llm_type: llm_type).deep_merge(generation_params)
  end

  def image_context_param
    raw = params.permit(image_context: [ :prompt, :response ])[:image_context]
    Array(raw).map { |t| { prompt: t[:prompt].to_s, response: t[:response].to_s } }
  end

  def image_param
    raw = params.permit(image: [ :mime, :data_b64 ])[:image]
    return nil if raw.blank?
    mime = raw[:mime].to_s
    data_b64 = raw[:data_b64].to_s
    return nil if mime.empty? || data_b64.empty?
    { mime: mime, data_b64: data_b64 }
  end

  # Chronologically-ordered list of images: historical entries first,
  # current turn's image last. Empty array if none.
  def images_param
    raw = params.permit(images: [ :mime, :data_b64 ])[:images]
    return [] if raw.blank?
    Array(raw).filter_map do |entry|
      mime = entry[:mime].to_s
      data_b64 = entry[:data_b64].to_s
      next if mime.empty? || data_b64.empty?
      { mime: mime, data_b64: data_b64 }
    end
  end

  # Role-tagged conversation history from the client. Optional — when
  # absent the facade falls back to the legacy single-`prompt`-string form.
  # See LlmRbFacade#seed_session_messages! for how these get pushed into
  # the LLM::Session buffer.
  ALLOWED_MESSAGE_ROLES = %w[user assistant system].freeze
  def messages_param
    raw = params.permit(messages: [ :role, :content ])[:messages]
    return nil if raw.blank?
    Array(raw).filter_map do |entry|
      role    = entry[:role].to_s
      content = entry[:content].to_s
      next if content.empty? || !ALLOWED_MESSAGE_ROLES.include?(role)
      { role: role, content: content }
    end
  end

  MAX_DOCUMENT_BYTES = 10 * 1024 * 1024 # 10 MB, matches chat_dev's cap
  ALLOWED_DOCUMENT_MIMES = %w[application/pdf].freeze
  # Providers whose llm.rb adapter routes PDFs as native document blocks.
  # `supports_vision?` is our first-line proxy for PDF capability, but it
  # over-includes Ollama (llm.rb's Ollama adapter rejects non-image files),
  # so this is a second-line gate on the provider layer specifically for docs.
  DOCUMENT_CAPABLE_LLM_TYPES = %w[anthropic google].freeze

  # Single document attachment for the current turn. v1 only accepts PDFs
  # (binary formats that providers handle as native document blocks); the
  # chat-side wraps text docs inline in the prompt, so those never reach
  # this endpoint as `document`.
  def document_param
    raw = params.permit(document: [ :mime, :data_b64 ])[:document]
    return nil if raw.blank?
    mime = raw[:mime].to_s
    data_b64 = raw[:data_b64].to_s
    return nil if mime.empty? || data_b64.empty?
    unless ALLOWED_DOCUMENT_MIMES.include?(mime)
      raise ArgumentError, "Unsupported document mime: #{mime} (allowed: #{ALLOWED_DOCUMENT_MIMES.join(', ')})"
    end
    # base64 encodes 3 bytes as 4 chars, so decoded bytes ≈ length * 3/4.
    # Bail before the base64 decode if the encoded length already exceeds
    # what a 10 MB decode would produce (with slack for padding).
    if data_b64.bytesize > (MAX_DOCUMENT_BYTES * 4 / 3) + 16
      raise ArgumentError, "Document exceeds #{MAX_DOCUMENT_BYTES / 1024 / 1024} MB limit"
    end
    { mime: mime, data_b64: data_b64 }
  end
end
