require "rails_helper"

# Integration spec for the web-facing McpServer CRUD endpoints. Drives the
# full Devise + controller stack with a signed-in user. The interesting
# concerns are:
#
#   * The before_action :set_mcp_server pattern (canonical Rails: a redirect
#     in the filter halts the action — verified by the foreign-user cases).
#   * Validation messages surfaced through the flash.
#   * The toggle endpoint flipping active state idempotently.
RSpec.describe "McpServer CRUD (web)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "u@example.com", google_id: "g-mcp-crud") }
  let(:base_path) { "/user/#{user.id}/mcp_servers" }

  before { sign_in user }

  describe "GET index" do
    it "renders successfully with no servers" do
      get base_path
      expect(response).to have_http_status(:ok)
    end

    it "lists only the current user's servers, not other users'" do
      mine = user.mcp_servers.create!(name: "mine", url: "https://mine.example.com/rpc")
      other = User.create!(email: "o@example.com", google_id: "g-other")
      _theirs = other.mcp_servers.create!(name: "theirs", url: "https://theirs.example.com/rpc")

      get base_path
      expect(response.body).to include(mine.name)
      expect(response.body).not_to include("theirs")
    end
  end

  describe "POST create" do
    it "creates a server and redirects with a notice" do
      expect {
        post base_path, params: {
          mcp_server: { name: "new", url: "https://new.example.com/rpc" }
        }
      }.to change(user.mcp_servers, :count).by(1)

      expect(response).to redirect_to(base_path)
      follow_redirect!
      expect(response.body).to include("MCP server has been added successfully")
      expect(user.mcp_servers.last.uuid).to be_present  # auto-assigned
      expect(user.mcp_servers.last.active).to be true   # default
    end

    it "alerts on invalid URL without creating a row" do
      expect {
        post base_path, params: {
          mcp_server: { name: "bad", url: "not-a-url" }
        }
      }.not_to change(user.mcp_servers, :count)

      follow_redirect!
      expect(response.body).to include("Failed to add MCP server")
      expect(response.body).to include("must be a valid HTTP or HTTPS URL")
    end

    it "alerts on missing mcp_server params" do
      post base_path, params: {}
      follow_redirect!
      expect(response.body).to include("Please enter server name and URL")
    end

    it "rejects a duplicate URL within the same user" do
      user.mcp_servers.create!(name: "first", url: "https://dup.example.com/rpc")

      expect {
        post base_path, params: {
          mcp_server: { name: "second", url: "https://dup.example.com/rpc" }
        }
      }.not_to change(user.mcp_servers, :count)

      follow_redirect!
      expect(response.body).to include("has already been registered")
    end
  end

  describe "PATCH update" do
    let!(:server) { user.mcp_servers.create!(name: "before", url: "https://before.example.com/rpc") }

    it "updates name and URL" do
      patch "#{base_path}/#{server.id}", params: {
        mcp_server: { name: "after", url: "https://after.example.com/rpc" }
      }
      follow_redirect!
      expect(response.body).to include("MCP server has been updated successfully")
      expect(server.reload.name).to eq("after")
      expect(server.url).to eq("https://after.example.com/rpc")
    end

    it "alerts on an invalid update without persisting" do
      patch "#{base_path}/#{server.id}", params: {
        mcp_server: { name: "", url: "https://after.example.com/rpc" }
      }
      follow_redirect!
      expect(response.body).to include("Failed to update MCP server")
      expect(server.reload.name).to eq("before")
    end

    it "isolates users: A cannot touch B's server (filter halts the action)" do
      other = User.create!(email: "o@example.com", google_id: "g-other")
      other_server = other.mcp_servers.create!(name: "theirs", url: "https://theirs.example.com/rpc")

      patch "#{base_path}/#{other_server.id}", params: {
        mcp_server: { name: "hijacked", url: "https://hijack.example.com/rpc" }
      }

      # The before_action redirected with an alert — the action never ran,
      # so the foreign record is untouched.
      expect(other_server.reload.name).to eq("theirs")
      expect(other_server.url).to eq("https://theirs.example.com/rpc")
      follow_redirect!
      expect(response.body).to include("specified MCP server was not found")
    end
  end

  describe "DELETE destroy" do
    let!(:server) { user.mcp_servers.create!(name: "remove-me", url: "https://gone.example.com/rpc") }

    it "deletes the server and the cascade also deletes its tools" do
      server.mcp_tools.create!(name: "t1", input_schema: { type: "object" })
      expect {
        delete "#{base_path}/#{server.id}"
      }.to change(McpTool, :count).by(-1)
        .and change(user.mcp_servers, :count).by(-1)

      follow_redirect!
      # Single quotes in the flash get HTML-escaped to &#39; in the rendered page.
      expect(response.body).to include("MCP server &#39;remove-me&#39; has been deleted successfully")
    end

    it "isolates users: A cannot delete B's server" do
      other = User.create!(email: "o@example.com", google_id: "g-other")
      other_server = other.mcp_servers.create!(name: "theirs", url: "https://theirs.example.com/rpc")

      expect {
        delete "#{base_path}/#{other_server.id}"
      }.not_to change(other.mcp_servers, :count)
    end
  end

  describe "PATCH toggle" do
    let!(:server) { user.mcp_servers.create!(name: "tog", url: "https://tog.example.com/rpc", active: true) }

    it "flips active off then back on with the right flash on each side" do
      patch "#{base_path}/#{server.id}/toggle"
      follow_redirect!
      expect(server.reload.active).to be false
      expect(response.body).to include("has been deactivated")

      patch "#{base_path}/#{server.id}/toggle"
      follow_redirect!
      expect(server.reload.active).to be true
      expect(response.body).to include("has been activated")
    end

    it "isolates users: A cannot toggle B's server" do
      other = User.create!(email: "o@example.com", google_id: "g-other")
      other_server = other.mcp_servers.create!(name: "theirs", url: "https://theirs.example.com/rpc", active: true)

      patch "#{base_path}/#{other_server.id}/toggle"
      expect(other_server.reload.active).to be true
    end
  end
end
