require "rails_helper"

# Integration spec for the JSON /api/mcp_servers endpoints, focused on the
# security boundary the existing controller_spec doesn't cover: per-user
# isolation through the full Devise + Google-ID-token + ApiController stack.
#
# The controller looks records up via `current_user.mcp_servers.find_by!(uuid:)`
# which raises RecordNotFound on a foreign UUID; ApiController rescues that
# into a 401 Unauthorized. This spec confirms that mapping end to end.
RSpec.describe "Api::McpServersController isolation + bad-param paths", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-mcp-iso") }
  let(:good_token) { "tok" }
  let(:auth_headers) { { "Authorization" => "Bearer #{good_token}" } }

  let(:other_user) { User.create!(email: "o@example.com", google_id: "g-other") }
  let!(:other_server) do
    other_user.mcp_servers.create!(name: "theirs", url: "https://theirs.example.com/rpc",
                                    active: true)
  end

  before do
    allow(GoogleIdTokenVerifier).to receive(:verify_all)
      .with(good_token).and_return("sub" => user.google_id)
  end

  describe "foreign-UUID isolation" do
    it "PATCH update on another user's uuid returns 401 and does not modify the row" do
      patch "/api/mcp_servers/#{other_server.uuid}",
            params: { mcp_server: { name: "hijack", url: "https://x.example.com/rpc" } },
            headers: auth_headers

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq("error" => "Unauthorized")
      expect(other_server.reload.name).to eq("theirs")
    end

    it "DELETE on another user's uuid returns 401 and does not delete the row" do
      expect {
        delete "/api/mcp_servers/#{other_server.uuid}", headers: auth_headers
      }.not_to change(McpServer, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "PATCH toggle on another user's uuid returns 401 and does not flip active" do
      patch "/api/mcp_servers/#{other_server.uuid}/toggle", headers: auth_headers

      expect(response).to have_http_status(:unauthorized)
      expect(other_server.reload.active).to be true
    end
  end

  describe "missing-param handling on create" do
    it "returns 400 when the mcp_server param wrapper is absent entirely" do
      post "/api/mcp_servers", params: {}, headers: auth_headers

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("Parameter missing")
    end

    it "returns 422 when the mcp_server wrapper is present but name and url are empty" do
      post "/api/mcp_servers",
           params: { mcp_server: { name: "", url: "" } },
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["error"]).to include("Name can't be blank")
      expect(body["error"]).to include("Url can't be blank")
    end
  end

  describe "index isolation" do
    it "lists only the current user's servers, never another user's" do
      user.mcp_servers.create!(name: "mine", url: "https://mine.example.com/rpc")

      get "/api/mcp_servers", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      uuids = body["mcp_servers"].map { |s| s["uuid"] }
      expect(uuids).not_to include(other_server.uuid)
      expect(uuids).to contain_exactly(user.mcp_servers.first.uuid)
    end
  end
end
