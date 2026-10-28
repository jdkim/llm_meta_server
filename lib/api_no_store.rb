# Removes the ETag from JSON API responses, so no revalidation can become a 304.
#
# Rack::ETag stamps any cacheable 200 with an ETag and
# "max-age=0, private, must-revalidate". A browser then revalidates on the next
# visit, Rack::ConditionalGet turns the match into 304 Not Modified, and the
# response has no body. A client that gates on fetch's `response.ok` — which is
# false for a 304 — reads an empty payload and degrades in silence. Our own
# widget did exactly that: on every repeat visit it lost the model's context
# window and the hub tool list, while working perfectly on a first load. Any
# consumer written the same reasonable way has the same bug, including copies
# of the widget we do not ship to.
#
# `Cache-Control: no-store` alone is not enough. It stops a compliant browser
# from STORING the answer, so it never asks — but if a conditional request
# arrives anyway, Rack::ConditionalGet still answers 304. Removing the ETag is
# what makes that impossible.
#
# Inserted BEFORE Rack::ETag, which puts it outside: on the way out the ETag is
# added first, stripped here, and Rack::ConditionalGet then has nothing to
# match. Nothing is given up — these payloads are small, caller-specific, and
# change whenever an administrator edits the catalog or registers a server.
class ApiNoStore
  PREFIX = "/api/"

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    return [ status, headers, body ] unless env["PATH_INFO"].to_s.start_with?(PREFIX)

    # Only the ETag. The caching POLICY is declared by ApiController, which runs
    # before Rack::ETag and so keeps its own value; an action that needs a
    # different one — the SSE endpoints say "no-cache" — sets it for itself.
    # Overwriting it here took that choice away and broke the streaming
    # contract.
    # One delete is enough: Rack 3's Headers is case-insensitive, so this also
    # removes the "ETag" spelling. Deleting both looked thorough and made a
    # mutation of either line a no-op, which hid whether the test could fail.
    headers.delete("etag")
    [ status, headers, body ]
  end
end
