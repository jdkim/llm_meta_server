require "stringio"
require "json"

# Runs before Rails parses JSON, including requests without Content-Length.
class AnonymousRequestBodyLimit
  PATH = %r{\A/api/(?:llm_api_keys/[^/]+/models/[^/]+/(?:single_llm_calls|chats|chat_streams)|mcp_tools/[^/]+/call)(?:\.[^/]+)?/?\z}

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["REQUEST_METHOD"] == "POST" && PATH.match?(env["PATH_INFO"].to_s)
    max = Integer(ENV.fetch("ANONYMOUS_BODY_BYTES", 262144))
    raise ArgumentError, "ANONYMOUS_BODY_BYTES must be positive" unless max.positive?
    return rejected if env["CONTENT_LENGTH"].to_i > max
    input = env["rack.input"]
    return @app.call(env) unless input
    body = +""
    while (chunk = input.read([ 16384, max + 1 - body.bytesize ].min)) && !chunk.empty?
      body << chunk
      return rejected if body.bytesize > max
    end
    env["rack.input"] = StringIO.new(body)
    @app.call(env)
  end

  private

  def rejected
    [ 413, { "content-type" => "application/json" },
      [ JSON.generate(error: "payload_too_large", message: "API request body exceeds the configured limit") ] ]
  end
end
