class Api::ChatStreamsController < ApiController
  include ActionController::Live

  wrap_parameters false

  GENERATION_PARAM_KEYS = %i[temperature top_p top_k max_tokens].freeze

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

    if bearer_token
      llm_api_key = current_user.find_llm_api_key uuid
      model_id = LlmModelMap.fetch! model_name, llm_type: llm_api_key&.llm_type
      if image.present? && !LlmModelMap.supports_vision?(model_name, llm_type: llm_api_key&.llm_type)
        raise ArgumentError, "Selected model doesn't support image input"
      end
      if LlmModelMap.image_model?(model_name, llm_type: llm_api_key&.llm_type)
        markdown = ImageGenerationService.generate!(
          model_id: model_id, prompt: prompt, llm_api_key: llm_api_key,
          image_context: image_context_param,
          image: image
        )
        sink << markdown
      else
        LlmRbFacade.stream! model_id, prompt,
          sink: sink,
          llm_api_key: llm_api_key,
          tools: selected_tools,
          generation_params: generation_params,
          image: image,
          on_tool_calls: on_tool_calls,
          on_phase_change: on_phase_change
      end
    else
      model_id = LlmModelMap.fetch! model_name
      if image.present? && !LlmModelMap.supports_vision?(model_name, llm_type: nil)
        raise ArgumentError, "Selected model doesn't support image input"
      end
      LlmRbFacade.stream! model_id, prompt,
        sink: sink,
        generation_params: generation_params,
        image: image,
        on_tool_calls: on_tool_calls,
        on_phase_change: on_phase_change
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

    McpToolAdapter.to_llm_functions(current_user.find_mcp_tools(tool_ids))
  end

  def generation_params
    params.permit(*GENERATION_PARAM_KEYS).to_h.symbolize_keys
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
end
