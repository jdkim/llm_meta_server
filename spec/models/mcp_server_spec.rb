require 'rails_helper'

RSpec.describe McpServer, type: :model do
  let(:user) { User.create!(email: "test@example.com", google_id: "123456") }

  describe '#valid?' do
    context 'with valid required attributes' do
      let(:server) { McpServer.new(user: user, name: "Test Server", url: "https://example.com/mcp") }

      it 'is valid and assigns a uuid' do
        expect(server).to be_valid
        expect(server).to have_attributes(
          user: user,
          uuid: kind_of(String),
          name: "Test Server",
          url: "https://example.com/mcp",
          active: true
        )
      end
    end

    context 'without name' do
      let(:server) { McpServer.new(user: user, url: "https://example.com/mcp") }

      it 'is not valid' do
        expect(server).not_to be_valid
        expect(server.errors[:name]).to include("can't be blank")
      end
    end

    context 'without url' do
      let(:server) { McpServer.new(user: user, name: "Test") }

      it 'is not valid' do
        expect(server).not_to be_valid
        expect(server.errors[:url]).to include("can't be blank")
      end
    end

    context 'with invalid url format' do
      let(:server) { McpServer.new(user: user, name: "Test", url: "ftp://example.com") }

      it 'is not valid' do
        expect(server).not_to be_valid
        expect(server.errors[:url]).to include("must be a valid HTTP or HTTPS URL")
      end
    end

    context 'with duplicate url for same user' do
      before do
        McpServer.create!(user: user, name: "Server 1", url: "https://example.com/mcp")
      end

      let(:server) { McpServer.new(user: user, name: "Server 2", url: "https://example.com/mcp") }

      it 'is not valid' do
        expect(server).not_to be_valid
        expect(server.errors[:url]).to include("has already been registered")
      end
    end

    context 'with same url for different users' do
      let(:user2) { User.create!(email: "test2@example.com", google_id: "654321") }

      before do
        McpServer.create!(user: user, name: "Server 1", url: "https://example.com/mcp")
      end

      let(:server) { McpServer.new(user: user2, name: "Server 2", url: "https://example.com/mcp") }

      it 'is valid' do
        expect(server).to be_valid
      end
    end
  end

  describe 'scopes' do
    before do
      McpServer.create!(user: user, name: "Active Server", url: "https://active.example.com/mcp", active: true)
      McpServer.create!(user: user, name: "Inactive Server", url: "https://inactive.example.com/mcp", active: false)
    end

    describe '.active' do
      it 'returns only active servers' do
        expect(McpServer.active.map(&:name)).to eq([ "Active Server" ])
      end
    end

    describe '.inactive' do
      it 'returns only inactive servers' do
        expect(McpServer.inactive.map(&:name)).to eq([ "Inactive Server" ])
      end
    end

    describe '.visible_to' do
      let(:other) { User.create!(email: "other@example.com", google_id: "g-other") }
      let!(:own_private) { McpServer.create!(user: other, name: "other-private", url: "https://o-priv.example.com/mcp", public: false, active: true) }
      let!(:own_public)  { McpServer.create!(user: other, name: "other-public",  url: "https://o-pub.example.com/mcp",  public: true,  active: true) }
      let!(:public_but_inactive) { McpServer.create!(user: other, name: "other-public-down", url: "https://o-down.example.com/mcp", public: true, active: false) }

      it "returns the viewer's own servers and other users' active+public servers" do
        names = McpServer.visible_to(user).pluck(:name)
        # 'Active Server' / 'Inactive Server' are this user's; both visible to owner.
        expect(names).to contain_exactly("Active Server", "Inactive Server", "other-public")
      end

      it "hides inactive public servers from non-owners" do
        names = McpServer.visible_to(user).pluck(:name)
        expect(names).not_to include("other-public-down")
      end

      it "shows the owner their own inactive public server" do
        names = McpServer.visible_to(other).pluck(:name)
        expect(names).to include("other-public-down")
      end

      it "with nil viewer returns only active+public (controller gates anonymous access)" do
        names = McpServer.visible_to(nil).pluck(:name)
        expect(names).to contain_exactly("other-public")
      end
    end
  end

  describe '#as_json' do
    let(:server) { McpServer.create!(user: user, name: "Test Server", url: "https://example.com/mcp") }

    it 'includes expected keys' do
      json = server.as_json
      expect(json.keys).to include("uuid", "name", "url", "active", "tools")
    end

    it 'does not include user_id' do
      json = server.as_json
      expect(json).not_to have_key("user_id")
      expect(json).not_to have_key("id")
    end

    it 'includes tools array' do
      json = server.as_json
      expect(json["tools"]).to eq([])
    end
  end

  describe 'dependent destroy' do
    let(:server) { McpServer.create!(user: user, name: "Test Server", url: "https://example.com/mcp") }

    before do
      server.mcp_tools.create!(name: "tool1", input_schema: { "type" => "object" })
    end

    it 'destroys associated tools when server is destroyed' do
      expect { server.destroy! }.to change(McpTool, :count).by(-1)
    end
  end
end
