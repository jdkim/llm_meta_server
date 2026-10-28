require "rails_helper"

# A 304 is the failure mode, not the ETag. Rack::ETag stamps a cacheable 200
# and the browser revalidates on the next visit; fetch reports `ok: false` for
# the 304 that comes back, and a client that trusts `ok` reads an empty
# payload. The widget lost the model's context window and the hub tool list
# that way on every repeat visit — the resource budget fell to its floor, and
# tool-result truncation and eviction stood down, each returning unchanged
# without a window.
#
# These specs run the real middleware stack, which is where Rack::ETag lives.
RSpec.describe "API cacheability", type: :request do
  %w[/api/llms /api/mcp_servers].each do |path|
    it "tells a browser not to store #{path}, so it never sends a conditional request" do
      get path

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("no-store")
      # Case-insensitively: rack 3 writes "etag", so asserting on "ETag" alone
      # passed whether or not the header was there.
      etags = response.headers.to_h.select { |name, _| name.downcase == "etag" }
      expect(etags).to be_empty, "an ETag is what lets a revalidation become a 304"
    end
  end

  it "answers a conditional request with the body rather than 304" do
    get "/api/llms"
    etag = response.headers.to_h.find { |name, _| name.downcase == "etag" }&.last

    get "/api/llms", headers: etag ? { "If-None-Match" => etag } : {}

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to be_empty
  end
end
