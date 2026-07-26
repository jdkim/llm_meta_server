# One LLM turn, streamed. The client owns the tool-execution loop: this
# endpoint calls the model once, streams text/thinking as it arrives, and
# emits any tool_calls the LLM wants dispatched — without executing them.
# The client is then responsible for dispatching (locally via aiActions, or
# by POSTing to the MCP proxy) and calling this endpoint again with the
# results appended to `messages`.
#
# Contrast with Api::ChatStreamsController, which runs the full
# request → tool_call → tool_exec → follow-up loop server-side.
class Api::SingleLlmCallsController < ApiController
  include ActionController::Live

  wrap_parameters false

  def create
    uuid, model_name = expected_params

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    sink = SingleLlmCallSseWriter.new(response.stream)
    on_phase_change = ->(name) { sink.phase(name) }

    sink.phase("thinking")
    heartbeat = start_heartbeat(sink)

    llm_api_key = bearer_token ? current_user.find_llm_api_key(uuid) : nil
    model_id = LlmModelMap.fetch! model_name, llm_type: llm_api_key&.llm_type

    result = LlmRbFacade.single_llm_turn!(
      llm_api_key: llm_api_key,
      model_id: model_id,
      tools: selected_tools,
      generation_params: effective_generation_params(model_name, llm_api_key&.llm_type),
      messages: messages_param,
      sink: sink,
      on_phase_change: on_phase_change
    )

    Array(result[:tool_calls]).each { |tc| sink.tool_call(tc) }
    sink.event("done", { content: result[:content], finish_reason: result[:finish_reason] })
  rescue ActionController::Live::ClientDisconnected
    Rails.logger.info "[SingleLlmCalls] client disconnected mid-stream"
  rescue LLM::RateLimitError => e
    safe_emit_error(sink, "rate_limit", e.message)
  rescue LlmApiKeyRequiredError => e
    safe_emit_error(sink, "api_key_required", e.message)
  rescue ArgumentError => e
    safe_emit_error(sink, "argument_error", e.message)
  rescue ModelNotFoundError => e
    safe_emit_error(sink, "model_not_found", e.message)
  rescue => e
    Rails.logger.error "[SingleLlmCalls] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
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
    params.permit(:llm_api_key_uuid, :model_name, tool_ids: [])
    params.expect(:llm_api_key_uuid, :model_name)
  end

  # For Phase 1 the client references remote MCP tools by ID (server-side
  # lookup keeps the DB authoritative for MCP schemas). Local page-embedded
  # tools (window.aiActions) will land as an inline `local_tools:` list here
  # in Phase 2.
  def selected_tools
    tool_ids = params.permit(tool_ids: [])[:tool_ids]
    return [] if tool_ids.blank?
    McpToolAdapter.to_llm_functions(McpTool.lookup(tool_ids, viewer: current_user))
  end

  def generation_params
    raw = params[:generation_settings]
    return {} if raw.blank?
    hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    hash.deep_symbolize_keys
  end

  def effective_generation_params(model_name, llm_type)
    LlmModelMap.defaults_for(model_name, llm_type: llm_type).deep_merge(generation_params)
  end

  # Role-tagged conversation history. Assistant messages that emitted
  # tool_calls, and tool-result messages, are permitted so the client can
  # replay a round-trip. NOTE: reconstructing prior assistant tool_calls
  # into the session buffer with full fidelity is a follow-up — right now
  # LlmRbFacade#messages_to_llm_objects drops assistant messages with empty
  # content, so a round-trip with server-side rehydration of the prior call
  # will lose the tool_call context. The fire-and-forget local-action path
  # (no result → no follow-up) is unaffected.
  ALLOWED_MESSAGE_ROLES = %w[user assistant system tool].freeze
  def messages_param
    raw = params.permit(
      messages: [
        :role, :content, :tool_call_id, :name,
        { tool_calls: [ :id, :name, { arguments: {} } ] }
      ]
    )[:messages]
    return nil if raw.blank?

    Array(raw).filter_map do |entry|
      role = entry[:role].to_s
      next unless ALLOWED_MESSAGE_ROLES.include?(role)

      msg = { role: role, content: entry[:content].to_s }
      msg[:tool_call_id] = entry[:tool_call_id].to_s if entry[:tool_call_id].present?
      msg[:name]         = entry[:name].to_s         if entry[:name].present?
      msg[:tool_calls]   = entry[:tool_calls].to_a   if entry[:tool_calls].present?
      msg
    end
  end
end
