class McpClient
  PROTOCOL_VERSION = "2025-03-26"
  JSON_RPC_VERSION = "2.0"
  CONTENT_TYPE = "application/json"
  ACCEPT_HEADER = "application/json, text/event-stream"

  class McpConnectionError < StandardError; end
  class McpProtocolError < StandardError; end

  attr_reader :url, :session_id, :server_info, :protocol_version

  def initialize(url)
    @url = url
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

    send_notification("notifications/initialized")

    result
  end

  def list_tools!
    response = send_request("tools/list", {})
    result = parse_result(response)
    result["tools"] || []
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
      raise McpConnectionError, "HTTP #{response.code}"
    end

    response
  rescue HTTParty::Error, Errno::ECONNREFUSED, SocketError, Timeout::Error => e
    raise McpConnectionError, "Failed to connect to MCP server: #{e.message}"
  end

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
  rescue HTTParty::Error, Errno::ECONNREFUSED, SocketError, Timeout::Error => e
    raise McpConnectionError, "Failed to send notification: #{e.message}"
  end

  def request_headers
    headers = {
      "Content-Type" => CONTENT_TYPE,
      "Accept" => ACCEPT_HEADER
    }
    headers["Mcp-Session-Id"] = @session_id if @session_id
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
