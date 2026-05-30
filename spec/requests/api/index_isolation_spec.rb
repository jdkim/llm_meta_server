require "rails_helper"

# Per-user data isolation across the JSON API's index endpoints. The
# existing controller specs cover happy paths but don't prove that a
# signed-in user can never observe another user's keys or tools through
# the catalog endpoints.
RSpec.describe "JSON API index isolation", type: :request do
  let(:user) { User.create!(email: "u@example.com", google_id: "g-iso-self") }
  let(:other_user) { User.create!(email: "o@example.com", google_id: "g-iso-other") }
  let(:auth_headers) { { "Authorization" => "Bearer self-tok" } }

  before do
    allow(GoogleIdTokenVerifier).to receive(:verify_all)
      .with("self-tok").and_return("sub" => user.google_id)
  end

  describe "GET /api/llm_api_keys" do
    it "returns only the signed-in user's keys, never another user's" do
      mine = user.llm_api_keys.create!(llm_type: "openai", description: "mine",
                                        encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-mine"))
      _theirs = other_user.llm_api_keys.create!(llm_type: "anthropic", description: "theirs",
                                                  encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-theirs"))

      get "/api/llm_api_keys", headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      uuids = body["llm_api_keys"].map { |k| k["uuid"] }
      expect(uuids).to contain_exactly(mine.uuid)
    end

    it "returns an empty list when the signed-in user has no keys, even if other users do" do
      other_user.llm_api_keys.create!(llm_type: "openai", description: "theirs",
                                       encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-theirs"))

      get "/api/llm_api_keys", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["llm_api_keys"]).to eq([])
    end
  end

  describe "GET /api/mcp_servers/:mcp_server_uuid/tools" do
    let!(:other_server) do
      other_user.mcp_servers.create!(name: "theirs", url: "https://theirs.example.com/rpc")
    end
    let!(:_other_tool) do
      other_server.mcp_tools.create!(name: "secret_tool", input_schema: { type: "object" })
    end

    it "returns 401 when the requesting user doesn't own the mcp_server_uuid" do
      get "/api/mcp_servers/#{other_server.uuid}/tools", headers: auth_headers

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq("error" => "Unauthorized")
    end

    it "lists only the signed-in user's tools when the uuid resolves to their own server" do
      my_server = user.mcp_servers.create!(name: "mine", url: "https://mine.example.com/rpc")
      my_tool = my_server.mcp_tools.create!(name: "my_tool", description: "x",
                                             input_schema: { type: "object" })

      # The endpoint calls McpToolFetcher#fetch! which would hit the MCP
      # server — stub the client so the spec stays offline. We're testing
      # the response shape, not the fetch behavior.
      mock_client = instance_double(McpClient)
      allow(McpClient).to receive(:new).with(my_server.url).and_return(mock_client)
      allow(mock_client).to receive(:initialize_connection!)
      allow(mock_client).to receive(:server_info).and_return("name" => "mine", "version" => "1")
      allow(mock_client).to receive(:protocol_version).and_return("2025-03-26")
      allow(mock_client).to receive(:list_tools!).and_return([
        { "name" => my_tool.name, "description" => my_tool.description,
          "inputSchema" => my_tool.input_schema }
      ])

      get "/api/mcp_servers/#{my_server.uuid}/tools", headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      names = body["tools"].map { |t| t["name"] }
      expect(names).to contain_exactly("my_tool")
      expect(names).not_to include("secret_tool")
    end
  end
end
