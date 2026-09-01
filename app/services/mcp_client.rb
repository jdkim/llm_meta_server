class McpClient
  PROTOCOL_VERSION = "2025-03-26"
  JSON_RPC_VERSION = "2.0"
  CONTENT_TYPE = "application/json"
  ACCEPT_HEADER = "application/json, text/event-stream"

  class McpConnectionError < StandardError; end
  class McpProtocolError < StandardError; end

  attr_reader :url, :session_id, :server_info, :protocol_version

  def initialize(url, auth_token: nil, caller_ip: nil)
    @url = url
    @auth_token = auth_token
    @caller_ip = caller_ip
    @session_id = nil
    @server_info = nil
    @protocol_version = nil
    @request_id = 0
  end

  def initialize_connection!
    response = send_request("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: {
        name: "llm_meta_server",
        version: "1.0.0"
      }
    })

    result = parse_result(response)
    @server_info = result["serverInfo"]
    @protocol_version = result["protocolVersion"]

    if @protocol_version.present? && @protocol_version != PROTOCOL_VERSION
      # MCP spec allows the server to negotiate a different protocol version
      # in the initialize response. We accept whatever the server offers but
      # surface it in logs so version-drift issues are diagnosable.
      Rails.logger.warn "[McpClient #{url}] protocol version negotiated: " \
        "requested #{PROTOCOL_VERSION}, server offered #{@protocol_version}"
    end

    send_notification("notifications/initialized")

    result
  end

  def list_tools!
    response = send_request("tools/list", {})
    result = parse_result(response)
    result["tools"] || []
  end

  def call_tool!(name, arguments = {})
    response = send_request("tools/call", { name: name, arguments: arguments })
    parse_result(response)
  end

  private

  def next_request_id
    @request_id += 1
  end

  def send_request(method, params)
    body = {
      jsonrpc: JSON_RPC_VERSION,
      id: next_request_id,
      method: method,
      params: params
    }

    response = HTTParty.post(url, {
      body: body.to_json,
      headers: request_headers,
      timeout: 30
    })

    update_session_id(response)

    unless response.success?
      raise McpConnectionError, "HTTP #{response.code} on #{method}"
    end

    response
  rescue HTTParty::Error, Errno::ECONNREFUSED, SocketError, Timeout::Error, Net::ReadTimeout, Net::OpenTimeout => e
    raise McpConnectionError, "Failed to send request '#{method}': #{e.message}"
  end

  # JSON-RPC 2.0 notifications are fire-and-forget: the server MUST NOT
  # respond. We POST the notification and treat post-write outcomes
  # (Net::ReadTimeout, or a clean TCP close observed as a read timeout on
  # the closed socket) as success — the write already reached the server.
  # Only pre-write failures (connect timeout, DNS failure, connection
  # refused) count as real errors, since those genuinely mean the
  # notification never left our host.
  #
  # Prior to this: a spec-conformant server that closed the connection
  # after receiving `notifications/initialized` (nothing to say back)
  # crashed initialize_connection! with Net::ReadTimeout, so the client
  # never got to tools/call. The MCP server would see `initialize` and
  # then nothing further — the exact symptom PubDictionaries flagged.
  def send_notification(method, params = {})
    body = {
      jsonrpc: JSON_RPC_VERSION,
      method: method,
      params: params
    }

    HTTParty.post(url, {
      body: body.to_json,
      headers: request_headers,
      timeout: 10
    })
  rescue Net::ReadTimeout => e
    # Write completed; server chose not to send a response (spec-compliant).
    Rails.logger.info "[McpClient #{url}] notification '#{method}' delivered; " \
      "no response (#{e.message}) — spec-compliant, continuing"
    nil
  rescue HTTParty::Error, Errno::ECONNREFUSED, SocketError, Timeout::Error, Net::OpenTimeout => e
    raise McpConnectionError, "Failed to send notification '#{method}': #{e.message}"
  end

  def request_headers
    headers = {
      "Content-Type" => CONTENT_TYPE,
      "Accept" => ACCEPT_HEADER
    }
    headers["Authorization"] = "Bearer #{@auth_token}" if @auth_token.present?
    headers["Mcp-Session-Id"] = @session_id if @session_id
    headers["X-Forwarded-For"] = @caller_ip if @caller_ip.present?
    headers
  end

  def update_session_id(response)
    new_session_id = response.headers["mcp-session-id"]
    @session_id = new_session_id if new_session_id
  end

  def parse_result(response)
    content_type = response.headers["content-type"] || ""

    if content_type.include?("text/event-stream")
      parse_sse_response(response.body)
    else
      parse_json_response(response.body)
    end
  end

  def parse_json_response(body)
    data = JSON.parse(body)

    if data["error"]
      raise McpProtocolError, "JSON-RPC error #{data['error']['code']}: #{data['error']['message']}"
    end

    data["result"] || data
  rescue JSON::ParserError => e
    raise McpProtocolError, "Invalid JSON response: #{e.message}"
  end

  def parse_sse_response(body)
    result = nil

    body.each_line do |line|
      line = line.strip
      next if line.empty? || line.start_with?(":")

      if line.start_with?("data: ")
        data_str = line.sub("data: ", "")
        data = JSON.parse(data_str)

        if data["error"]
          raise McpProtocolError, "JSON-RPC error #{data['error']['code']}: #{data['error']['message']}"
        end

        result = data["result"] if data["result"]
      end
    end

    raise McpProtocolError, "No result found in SSE response" unless result
    result
  rescue JSON::ParserError => e
    raise McpProtocolError, "Invalid SSE response: #{e.message}"
  end
end
