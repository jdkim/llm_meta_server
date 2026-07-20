require 'rails_helper'

RSpec.describe McpTool, type: :model do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }
  let(:server) { McpServer.create!(user: user, name: "Test Server", url: "https://example.com/mcp") }

  describe '#valid?' do
    context 'with valid attributes' do
      let(:tool) { McpTool.new(mcp_server: server, name: "read_file", input_schema: { "type" => "object" }) }

      it 'is valid' do
        expect(tool).to be_valid
        expect(tool).to have_attributes(
          name: "read_file",
          active: true
        )
      end
    end

    context 'without name' do
      let(:tool) { McpTool.new(mcp_server: server, input_schema: { "type" => "object" }) }

      it 'is not valid' do
        expect(tool).not_to be_valid
        expect(tool.errors[:name]).to include("can't be blank")
      end
    end

    context 'without input_schema' do
      let(:tool) { McpTool.new(mcp_server: server, name: "read_file") }

      it 'is not valid' do
        expect(tool).not_to be_valid
        expect(tool.errors[:input_schema]).to include("can't be blank")
      end
    end

    context 'with duplicate name for same server' do
      before do
        McpTool.create!(mcp_server: server, name: "read_file", input_schema: { "type" => "object" })
      end

      let(:tool) { McpTool.new(mcp_server: server, name: "read_file", input_schema: { "type" => "object" }) }

      it 'is not valid' do
        expect(tool).not_to be_valid
        expect(tool.errors[:name]).to include("has already been taken")
      end
    end
  end

  describe 'scopes' do
    before do
      McpTool.create!(mcp_server: server, name: "active_tool", input_schema: { "type" => "object" }, active: true)
      McpTool.create!(mcp_server: server, name: "inactive_tool", input_schema: { "type" => "object" }, active: false)
    end

    describe '.active' do
      it 'returns only active tools' do
        expect(McpTool.active.map(&:name)).to eq([ "active_tool" ])
      end
    end

    describe '.inactive' do
      it 'returns only inactive tools' do
        expect(McpTool.inactive.map(&:name)).to eq([ "inactive_tool" ])
      end
    end
  end

  describe '#as_json' do
    let(:tool) { McpTool.create!(mcp_server: server, name: "read_file", description: "Read a file", input_schema: { "type" => "object" }) }

    it 'includes expected keys' do
      json = tool.as_json
      expect(json.keys).to match_array(%w[id name description input_schema active annotations])
    end

    it 'does not include mcp_server_id' do
      json = tool.as_json
      expect(json).not_to have_key("mcp_server_id")
    end
  end

  describe 'annotation accessors' do
    let(:tool) do
      McpTool.create!(mcp_server: server, name: "read_file",
                      input_schema: { "type" => "object" },
                      annotations: annotations_hash)
    end

    context 'when the server sets every hint' do
      let(:annotations_hash) do
        {
          "title" => "Read a file",
          "readOnlyHint" => true,
          "destructiveHint" => true,
          "idempotentHint" => true,
          "openWorldHint" => true
        }
      end

      it 'surfaces every accessor as true and returns the title' do
        expect(tool.title).to eq("Read a file")
        expect(tool.read_only_hint?).to be true
        expect(tool.destructive_hint?).to be true
        expect(tool.idempotent_hint?).to be true
        expect(tool.open_world_hint?).to be true
      end
    end

    context 'when the server omits hints (empty annotations)' do
      let(:annotations_hash) { {} }

      it 'returns false for every hint (missing hint means no claim, treated as absent)' do
        expect(tool.title).to be_nil
        expect(tool.read_only_hint?).to be false
        expect(tool.destructive_hint?).to be false
        expect(tool.idempotent_hint?).to be false
        expect(tool.open_world_hint?).to be false
      end
    end

    context 'when a hint is explicitly set to false' do
      let(:annotations_hash) { { "readOnlyHint" => false, "destructiveHint" => true } }

      it 'returns false for the false hint and true for the true one' do
        expect(tool.read_only_hint?).to be false
        expect(tool.destructive_hint?).to be true
      end
    end

    context 'when annotations column is nil (pre-migration rows)' do
      # Simulate by writing nil directly, bypassing the default.
      it 'defaults to false for all hints without raising' do
        raw = McpTool.create!(mcp_server: server, name: "raw", input_schema: { "type" => "object" })
        raw.update_column(:annotations, nil)
        raw.reload
        expect(raw.annotations).to be_nil
        expect { raw.read_only_hint? }.not_to raise_error
        expect(raw.read_only_hint?).to be false
        expect(raw.title).to be_nil
      end
    end
  end

  describe '.lookup' do
    let(:owner) { user }
    let(:viewer) { User.create!(email: "viewer@example.com", google_id: "g-viewer") }
    let(:other_user) { User.create!(email: "stranger@example.com", google_id: "g-stranger") }

    let(:own_server)     { McpServer.create!(user: owner,      name: "Own",     url: "https://own.example.com/mcp",     active: true,  public: false) }
    let(:public_server)  { McpServer.create!(user: other_user, name: "Public",  url: "https://pub.example.com/mcp",     active: true,  public: true) }
    let(:private_server) { McpServer.create!(user: other_user, name: "Private", url: "https://priv.example.com/mcp",    active: true,  public: false) }
    let(:dead_server)    { McpServer.create!(user: other_user, name: "Dead",    url: "https://dead.example.com/mcp",    active: false, public: true) }

    let!(:own_tool)     { McpTool.create!(mcp_server: own_server,     name: "own",     input_schema: { "type" => "object" }, active: true) }
    let!(:pub_tool)     { McpTool.create!(mcp_server: public_server,  name: "pub",     input_schema: { "type" => "object" }, active: true) }
    let!(:pub_inactive) { McpTool.create!(mcp_server: public_server,  name: "pub-off", input_schema: { "type" => "object" }, active: false) }
    let!(:priv_tool)    { McpTool.create!(mcp_server: private_server, name: "priv",    input_schema: { "type" => "object" }, active: true) }
    let!(:dead_tool)    { McpTool.create!(mcp_server: dead_server,    name: "dead",    input_schema: { "type" => "object" }, active: true) }

    it "returns the viewer's own active tools" do
      expect(McpTool.lookup([ own_tool.id ], viewer: owner).pluck(:name)).to contain_exactly("own")
    end

    it "exposes tools from other users' active+public servers" do
      expect(McpTool.lookup([ pub_tool.id ], viewer: viewer).pluck(:name)).to contain_exactly("pub")
    end

    it "blocks tools from other users' private servers" do
      expect(McpTool.lookup([ priv_tool.id ], viewer: viewer)).to be_empty
    end

    it "blocks tools belonging to a public-but-inactive server" do
      expect(McpTool.lookup([ dead_tool.id ], viewer: viewer)).to be_empty
    end

    it "drops tools that are themselves inactive even when the server is visible" do
      expect(McpTool.lookup([ pub_inactive.id ], viewer: viewer)).to be_empty
    end

    it "returns none for an empty/blank tool_ids list" do
      expect(McpTool.lookup([], viewer: viewer)).to be_empty
      expect(McpTool.lookup(nil, viewer: viewer)).to be_empty
    end
  end
end
