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
    allow(McpClient).to receive(:new).with(mcp_server.url, auth_token: nil).and_return(mock_client)
    allow(mock_client).to receive(:initialize_connection!)
    allow(mock_client).to receive(:server_info).and_return(server_info)
    allow(mock_client).to receive(:protocol_version).and_return(protocol_version)
    allow(mock_client).to receive(:list_tools!).and_return(tools_data)
  end

  describe '#fetch!' do
    it 'creates tools in the database' do
      expect { fetcher.fetch! }.to change(McpTool, :count).by(2)
    end

    it "threads the server's auth_token into McpClient.new when the server has one" do
      # Fresh server with a token; use its own McpClient stub so the default
      # `before` (auth_token: nil) doesn't shadow this expectation.
      authed_server = McpServer.create!(user: user, name: "AuthedSrv", url: "https://authed.example.com/mcp")
      authed_server.auth_token = "mcp_secret_token"
      authed_server.save!

      expect(McpClient).to receive(:new).with(authed_server.url, auth_token: "mcp_secret_token").and_return(mock_client)

      described_class.new(authed_server).fetch!
    end

    context "when tools carry MCP annotations" do
      let(:tools_data) do
        [
          {
            "name" => "read_file",
            "description" => "Read a file",
            "inputSchema" => { "type" => "object" },
            "annotations" => {
              "title" => "File reader",
              "readOnlyHint" => true,
              "openWorldHint" => false
            }
          },
          {
            "name" => "delete_file",
            "description" => "Delete a file",
            "inputSchema" => { "type" => "object" },
            "annotations" => { "destructiveHint" => true, "idempotentHint" => true }
          },
          {
            "name" => "no_hints",
            "description" => "Nothing to declare",
            "inputSchema" => { "type" => "object" }
            # no "annotations" key at all
          }
        ]
      end

      it "persists annotations verbatim and surfaces them through model accessors" do
        fetcher.fetch!

        rf = mcp_server.mcp_tools.find_by!(name: "read_file")
        expect(rf.annotations).to include("title" => "File reader", "readOnlyHint" => true, "openWorldHint" => false)
        expect(rf.title).to eq("File reader")
        expect(rf.read_only_hint?).to be true
        expect(rf.open_world_hint?).to be false

        del = mcp_server.mcp_tools.find_by!(name: "delete_file")
        expect(del.destructive_hint?).to be true
        expect(del.idempotent_hint?).to be true

        none = mcp_server.mcp_tools.find_by!(name: "no_hints")
        expect(none.annotations).to eq({}) # column default
        expect(none.read_only_hint?).to be false
      end

      it "updates annotations on subsequent fetches (server tightening/relaxing hints)" do
        fetcher.fetch!
        rf = mcp_server.mcp_tools.find_by!(name: "read_file")
        expect(rf.destructive_hint?).to be false

        # Second fetch: the server now flags read_file as destructive.
        allow(mock_client).to receive(:list_tools!).and_return([
          {
            "name" => "read_file",
            "description" => "Read a file",
            "inputSchema" => { "type" => "object" },
            "annotations" => { "destructiveHint" => true }
          }
        ])
        fetcher.fetch!
        expect(rf.reload.destructive_hint?).to be true
        expect(rf.read_only_hint?).to be false # replaced, not merged
      end

      it "clears the stored annotations when a subsequent fetch omits the annotations key" do
        fetcher.fetch!
        rf = mcp_server.mcp_tools.find_by!(name: "read_file")
        expect(rf.read_only_hint?).to be true # sanity: baseline had readOnlyHint: true

        # Server retracts all hints — the tool descriptor no longer carries an annotations block.
        allow(mock_client).to receive(:list_tools!).and_return([
          {
            "name" => "read_file",
            "description" => "Read a file",
            "inputSchema" => { "type" => "object" }
            # no "annotations" key
          }
        ])
        fetcher.fetch!

        rf.reload
        expect(rf.annotations).to eq({}) # cleared, not preserved
        expect(rf.read_only_hint?).to be false
        expect(rf.destructive_hint?).to be false
        expect(rf.title).to be_nil
      end
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
