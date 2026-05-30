require "rails_helper"

# Tests for the Authorization-header parsing in ApiController#bearer_token.
# This is the boundary that decides which string gets handed to the
# GoogleIdTokenVerifier; downstream specs all stub the verifier, so a
# regression here (e.g. accepting an empty string and treating it as
# "authenticated") would otherwise be invisible.
#
# The spec captures the parsed token by intercepting GoogleIdTokenVerifier
# and asserting what it received — that's exactly the boundary value of
# interest. /api/llms is the simplest authenticated endpoint to hit.
RSpec.describe "Authorization header parsing on the JSON API", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-bearer") }

  # Capture whatever bearer_token resolves to, then short-circuit the
  # verifier to a known-good payload so the request completes with 200.
  def capture_parsed_token
    received = []
    allow(GoogleIdTokenVerifier).to receive(:verify_all) do |tok|
      received << tok
      { "sub" => user.google_id }
    end
    yield
    received
  end

  describe "valid 'Bearer <token>' headers" do
    it "extracts the token verbatim from 'Bearer <token>'" do
      tokens = capture_parsed_token do
        get "/api/llms", headers: { "Authorization" => "Bearer good-tok" }
      end

      expect(response).to have_http_status(:ok)
      expect(tokens).to eq([ "good-tok" ])
    end

    it "handles a double space between 'Bearer' and the token (split-on-space normalization)" do
      tokens = capture_parsed_token do
        get "/api/llms", headers: { "Authorization" => "Bearer  spaced-tok" }
      end

      expect(tokens).to eq([ "spaced-tok" ])
    end
  end

  describe "headers that should NOT authenticate" do
    it "treats a missing Authorization header as unauthenticated (no verifier call)" do
      called = false
      allow(GoogleIdTokenVerifier).to receive(:verify_all) { called = true }

      get "/api/llms"

      # The endpoint requires auth → verifier never reached → ApiController
      # raises ParameterMissing on the blank token → mapped to 400.
      expect(called).to be(false)
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a lowercase 'bearer ' prefix (scheme is case-sensitive in the current parser)" do
      called = false
      allow(GoogleIdTokenVerifier).to receive(:verify_all) { called = true }

      get "/api/llms", headers: { "Authorization" => "bearer good-tok" }

      expect(called).to be(false)
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a non-Bearer scheme like 'Token <x>'" do
      called = false
      allow(GoogleIdTokenVerifier).to receive(:verify_all) { called = true }

      get "/api/llms", headers: { "Authorization" => "Token good-tok" }

      expect(called).to be(false)
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a tab separator (start_with?('Bearer ') requires a literal space)" do
      called = false
      allow(GoogleIdTokenVerifier).to receive(:verify_all) { called = true }

      get "/api/llms", headers: { "Authorization" => "Bearer\tgood-tok" }

      expect(called).to be(false)
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "edge-case parsing quirks (documented current behavior)" do
    # Bug: `"Bearer ".split(" ")` returns `["Bearer"]` — Ruby's split-on-
    # single-space drops trailing empties — so the parser hands the literal
    # string "Bearer" to the verifier. JWT.decode then rejects it as a
    # malformed token, so the practical outcome is still a 401, not an
    # auth bypass — but the diagnostic is misleading. A regex-based parser
    # would correctly return nil here.
    it "currently passes the literal string 'Bearer' to the verifier when the token is empty" do
      tokens = capture_parsed_token do
        get "/api/llms", headers: { "Authorization" => "Bearer " }
      end

      expect(tokens).to eq([ "Bearer" ])
    end

    # Bug: tokens with internal whitespace are truncated to their last
    # space-separated piece. JWTs themselves never contain spaces so this
    # is mostly theoretical, but worth pinning.
    it "currently drops everything before the last space in a multi-word token" do
      tokens = capture_parsed_token do
        get "/api/llms", headers: { "Authorization" => "Bearer abc def ghi" }
      end

      expect(tokens).to eq([ "ghi" ])
    end
  end
end
