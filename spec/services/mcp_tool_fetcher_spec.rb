require 'rails_helper'

RSpec.describe McpToolFetcher do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }
  let(:mcp_server) { McpServer.create!(user: user, name: "Test Server", url: "https://example.com/mcp") }
  let(:fetcher) { described_class.new(mcp_server) }

  let(:mock_client) { instance_double(McpClient) }
  let(:server_info) { { "name" => "test-server", "version" => "1.0.0" } }
  let(:protocol_version) { "2025-03-26" }

  let(:tools_data) do
    [
      {
        "name" => "read_file",
        "description" => "Read a file from disk",
        "inputSchema" => { "type" => "object", "properties" => { "path" => { "type" => "string" } } }
      },
      {
        "name" => "write_file",
        "description" => "Write a file to disk",
        "inputSchema" => { "type" => "object", "properties" => { "path" => { "type" => "string" }, "content" => { "type" => "string" } } }
      }
    ]
  end

  before do
    allow(McpClient).to receive(:new).with(mcp_server.url).and_return(mock_client)
    allow(mock_client).to receive(:initialize_connection!)
    allow(mock_client).to receive(:server_info).and_return(server_info)
    allow(mock_client).to receive(:protocol_version).and_return(protocol_version)
    allow(mock_client).to receive(:list_tools!).and_return(tools_data)
  end

  describe '#fetch!' do
    it 'creates tools in the database' do
      expect { fetcher.fetch! }.to change(McpTool, :count).by(2)
    end

    it 'updates server info' do
      fetcher.fetch!
      mcp_server.reload

      expect(mcp_server.server_name).to eq("test-server")
      expect(mcp_server.server_version).to eq("1.0.0")
      expect(mcp_server.protocol_version).to eq("2025-03-26")
      expect(mcp_server.last_fetched_at).to be_present
      expect(mcp_server.last_error).to be_nil
    end

    it 'returns tools data' do
      result = fetcher.fetch!
      expect(result.length).to eq(2)
      expect(result[0]["name"]).to eq("read_file")
    end

    context 'when syncing existing tools' do
      before do
        mcp_server.mcp_tools.create!(name: "read_file", description: "Old description", input_schema: { "type" => "object" })
        mcp_server.mcp_tools.create!(name: "obsolete_tool", input_schema: { "type" => "object" })
      end

      it 'updates existing tools' do
        fetcher.fetch!
        tool = mcp_server.mcp_tools.find_by(name: "read_file")
        expect(tool.description).to eq("Read a file from disk")
      end

      it 'removes obsolete tools' do
        fetcher.fetch!
        expect(mcp_server.mcp_tools.find_by(name: "obsolete_tool")).to be_nil
      end

      it 'creates new tools' do
        fetcher.fetch!
        expect(mcp_server.mcp_tools.find_by(name: "write_file")).to be_present
      end

      it 'preserves active state of existing tools' do
        mcp_server.mcp_tools.find_by(name: "read_file").update!(active: false)
        fetcher.fetch!
        tool = mcp_server.mcp_tools.find_by(name: "read_file")
        expect(tool.active).to be false
      end
    end

    context 'when connection fails' do
      before do
        allow(mock_client).to receive(:initialize_connection!)
          .and_raise(McpClient::McpConnectionError, "Connection refused")
      end

      it 'records the error on the server' do
        expect { fetcher.fetch! }.to raise_error(McpClient::McpConnectionError)
        mcp_server.reload
        expect(mcp_server.last_error).to eq("Connection refused")
      end
    end
  end
end
