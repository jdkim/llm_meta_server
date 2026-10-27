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
    # Two ceilings, because this middleware cannot tell a valid token from a
    # forged one and must not be the place that decides. A caller presenting an
    # Authorization header is spending its own key and may legitimately post a
    # long conversation or an extracted document, so it gets the larger bound;
    # ApiController rejects the header if it turns out to be invalid. Anonymous
    # callers get the strict one. Applying the anonymous cap to everybody, as
    # the variable name suggests it would, capped authenticated chats at 1 MiB.
    max = if env["HTTP_AUTHORIZATION"].present?
      Integer(ENV.fetch("AUTHENTICATED_BODY_BYTES", 8388608))
    else
      Integer(ENV.fetch("ANONYMOUS_BODY_BYTES", 1048576))
    end
    raise ArgumentError, "Body limits must be positive" unless max.positive?
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
