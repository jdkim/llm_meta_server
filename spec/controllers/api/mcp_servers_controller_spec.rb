require 'rails_helper'

RSpec.describe Api::McpServersController, type: :controller do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }

  before do
    allow(controller).to receive(:authenticate_user!).and_return(true)
    allow(controller).to receive(:current_user).and_return(user)
    # Signed-in path is discriminated by presence of a bearer token; stubs
    # must reflect that or the controller falls into the anon branch and
    # calls McpServer.visible_to(nil) (only public_to_anonymous servers).
    allow(controller).to receive(:bearer_token).and_return("stub-bearer")
  end

  describe 'GET #index' do
    context 'when user has no MCP servers' do
      it 'returns empty array' do
        get :index

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json['mcp_servers']).to eq([])
      end
    end

    context 'when user has MCP servers' do
      before do
        McpServer.create!(user: user, name: "Server 1", url: "https://example1.com/mcp")
        McpServer.create!(user: user, name: "Server 2", url: "https://example2.com/mcp")
      end

      it 'returns all servers' do
        get :index

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json['mcp_servers'].length).to eq(2)

        names = json['mcp_servers'].map { it['name'] }
        expect(names).to contain_exactly('Server 1', 'Server 2')
      end
    end

    context 'anonymous caller (no bearer token)' do
      # A bearer-less request must be served — that's how the chat's
      # tool_selector fetches the list for an unsigned visitor. Only
      # public_to_anonymous servers are exposed, and shared_by (owner
      # email) must NOT appear in the payload.
      before do
        allow(controller).to receive(:bearer_token).and_return(nil)
        McpServer.create!(user: user, name: "private", url: "https://priv.example.com/mcp")
        McpServer.create!(user: user, name: "shared-signed-in-only", url: "https://pub.example.com/mcp",
                          public: true, public_to_anonymous: false, active: true)
        McpServer.create!(user: user, name: "shared-anon", url: "https://anon.example.com/mcp",
                          public: true, public_to_anonymous: true, active: true)
      end

      it 'returns only public_to_anonymous servers' do
        get :index
        json = JSON.parse(response.body)
        expect(json['mcp_servers'].map { it['name'] }).to contain_exactly('shared-anon')
      end

      it 'omits shared_by (owner email) from every entry' do
        get :index
        json = JSON.parse(response.body)
        expect(json['mcp_servers']).to all(satisfy { |s| !s.key?('shared_by') })
      end

      it 'marks every entry as owned: false' do
        get :index
        json = JSON.parse(response.body)
        expect(json['mcp_servers']).to all(include('owned' => false))
      end
    end
  end

  describe 'POST #create' do
    context 'with valid params' do
      it 'creates a new MCP server' do
        expect {
          post :create, params: { mcp_server: { name: "New Server", url: "https://new.example.com/mcp" } }
        }.to change(McpServer, :count).by(1)

        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json['name']).to eq("New Server")
        expect(json['url']).to eq("https://new.example.com/mcp")
        expect(json['uuid']).to be_present
      end
    end

    context 'with invalid params' do
      it 'returns unprocessable entity' do
        post :create, params: { mcp_server: { name: "", url: "" } }

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json['error']).to be_present
      end
    end
  end

  describe 'PATCH #update' do
    let(:server) { McpServer.create!(user: user, name: "Old Name", url: "https://old.example.com/mcp") }

    context 'with valid params' do
      it 'updates the server' do
        patch :update, params: { uuid: server.uuid, mcp_server: { name: "New Name", url: "https://new.example.com/mcp" } }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json['name']).to eq("New Name")
        expect(json['url']).to eq("https://new.example.com/mcp")
      end
    end

    context 'with invalid params' do
      it 'returns unprocessable entity' do
        patch :update, params: { uuid: server.uuid, mcp_server: { name: "", url: "" } }

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe 'DELETE #destroy' do
    let!(:server) { McpServer.create!(user: user, name: "To Delete", url: "https://delete.example.com/mcp") }

    it 'deletes the server' do
      expect {
        delete :destroy, params: { uuid: server.uuid }
      }.to change(McpServer, :count).by(-1)

      expect(response).to have_http_status(:success)
    end
  end

  describe 'PATCH #toggle' do
    let(:server) { McpServer.create!(user: user, name: "Toggle Server", url: "https://toggle.example.com/mcp", active: true) }

    it 'toggles active state' do
      patch :toggle, params: { uuid: server.uuid }

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)
      expect(json['active']).to be false

      patch :toggle, params: { uuid: server.uuid }

      json = JSON.parse(response.body)
      expect(json['active']).to be true
    end
  end

  describe 'auth token is never leaked on the API surface' do
    let!(:server) do
      s = McpServer.create!(user: user, name: "authed", url: "https://authed.example.com/mcp")
      s.auth_token = "mcp_supersecret_token"
      s.save!
      s
    end

    it "GET #index omits the plaintext and encrypted token but exposes has_auth_token=true" do
      get :index
      body = response.body
      expect(body).not_to include("mcp_supersecret_token")
      expect(body).not_to include(server.encrypted_auth_token)

      row = JSON.parse(body)['mcp_servers'].find { |s| s['name'] == 'authed' }
      expect(row['has_auth_token']).to be true
      expect(row).not_to have_key('auth_token')
      expect(row).not_to have_key('encrypted_auth_token')
    end
  end
end
