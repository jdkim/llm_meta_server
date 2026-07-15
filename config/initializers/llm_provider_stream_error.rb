# Patch llm.rb's Provider#execute streaming branch to handle non-success
# upstream responses gracefully.
#
# Stock code (provider.rb:340-353) unconditionally feeds the response body
# through the SSE event-stream parser, then calls LLM::Object.from(parser.body)
# — which expects a Hash. When the upstream returns a JSON error payload
# (rate limit, auth error, etc.) the parser.body is the raw JSON string and
# the call NoMethodErrors with "undefined method 'each' for an instance of
# String", masking the real error and preventing the provider's error_handler
# from converting it to LLM::RateLimitError / LLM::UnauthorizedError / etc.
#
# Fix: skip the streaming parse on non-success responses; just read the body
# as a plain string so handle_response → error_handler.raise_error! sees the
# real JSON and raises the right LLM::Error subclass.

require "llm/provider"

class LLM::Provider
  remove_method :execute if instance_methods(false).include?(:execute)

  def execute(request:, operation:, stream: nil, stream_parser: self.stream_parser, model: nil, &b)
    span = @tracer.on_request_start(operation:, model:)
    args = (Net::HTTP === client) ? [ request ] : [ URI.join(base_uri, request.path), request ]
    res = if stream
      client.request(*args) do |res|
        if Net::HTTPSuccess === res
          handler = event_handler.new stream_parser.new(stream)
          parser = LLM::EventStream::Parser.new
          parser.register(handler)
          res.read_body(parser)
          res.body = LLM::Object.from(handler.body.empty? ? parser.body : handler.body)
        else
          # Non-success: let Net::HTTP fill res.body with the raw error JSON
          # so error_handler.raise_error! can parse it and raise the
          # appropriate LLM::Error subclass (RateLimitError, etc.).
          res.read_body
        end
      ensure
        parser&.free
      end
    else
      b ? client.request(*args) { (Net::HTTPSuccess === _1) ? b.call(_1) : _1 } :
          client.request(*args)
    end
    [ handle_response(res, span), span ]
  end
end
