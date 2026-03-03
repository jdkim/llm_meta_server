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
      expect(json.keys).to match_array(%w[id name description input_schema active])
    end

    it 'does not include mcp_server_id' do
      json = tool.as_json
      expect(json).not_to have_key("mcp_server_id")
    end
  end
end
