require 'rails_helper'

RSpec.describe Api::McpToolsController, type: :controller do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }
  let(:server) { McpServer.create!(user: user, name: "Test Server", url: "https://example.com/mcp") }

  before do
    allow(controller).to receive(:authenticate_user!).and_return(true)
    allow(controller).to receive(:current_user).and_return(user)
  end

  describe 'GET #index' do
    let(:mock_fetcher) { instance_double(McpToolFetcher) }

    before do
      allow(McpToolFetcher).to receive(:new).with(server).and_return(mock_fetcher)
    end

    context 'when fetch succeeds' do
      before do
        allow(mock_fetcher).to receive(:fetch!).and_return([])
      end

      it 'fetches tools and returns them' do
        get :index, params: { mcp_server_uuid: server.uuid }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json).to have_key('tools')
        expect(McpToolFetcher).to have_received(:new).with(server)
        expect(mock_fetcher).to have_received(:fetch!)
      end
    end

    context 'when connection fails' do
      before do
        allow(mock_fetcher).to receive(:fetch!).and_raise(McpClient::McpConnectionError, "Connection refused")
      end

      it 'returns bad gateway' do
        get :index, params: { mcp_server_uuid: server.uuid }

        expect(response).to have_http_status(:bad_gateway)
        json = JSON.parse(response.body)
        expect(json['error']).to include("Connection refused")
      end
    end

    context 'when protocol error occurs' do
      before do
        allow(mock_fetcher).to receive(:fetch!).and_raise(McpClient::McpProtocolError, "Invalid response")
      end

      it 'returns bad gateway' do
        get :index, params: { mcp_server_uuid: server.uuid }

        expect(response).to have_http_status(:bad_gateway)
        json = JSON.parse(response.body)
        expect(json['error']).to include("Invalid response")
      end
    end
  end

  describe 'PATCH #toggle' do
    let!(:tool) { McpTool.create!(mcp_server: server, name: "toggle_tool", input_schema: { "type" => "object" }, active: true) }

    it 'toggles tool active state' do
      patch :toggle, params: { mcp_server_uuid: server.uuid, id: tool.id }

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)
      expect(json['active']).to be false

      patch :toggle, params: { mcp_server_uuid: server.uuid, id: tool.id }

      json = JSON.parse(response.body)
      expect(json['active']).to be true
    end
  end
end
