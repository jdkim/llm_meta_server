class McpServer < ApplicationRecord
  belongs_to :user
  has_many :mcp_tools, dependent: :destroy

  validates :uuid, uniqueness: true
  validates :name, presence: true
  validates :url, presence: true, format: { with: /\Ahttps?:\/\/.+\z/i, message: "must be a valid HTTP or HTTPS URL" }
  validates :url, uniqueness: { scope: :user_id, message: "has already been registered" }

  before_validation :set_uuid

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  # Servers a given user is allowed to see in their tool picker:
  # everything they own, plus active public servers from anyone else.
  # Inactive public servers are excluded so a temporarily-down public
  # server doesn't clutter consumers' UIs.
  scope :visible_to, ->(user) {
    user_id = user&.id
    if user_id
      # Qualify columns so this stays unambiguous when merged into a join
      # that already references `mcp_tools.active` (see McpTool.lookup).
      where("mcp_servers.user_id = :uid OR (mcp_servers.public = :p AND mcp_servers.active = :a)",
            uid: user_id, p: true, a: true)
    else
      where(mcp_servers: { public: true, active: true })
    end
  }

  def as_json(options = {})
    super({ only: %i[uuid name url active public server_name server_version protocol_version last_fetched_at last_error] }.merge(options))
      .merge(
        "tools" => mcp_tools.map(&:as_json)
      )
  end

  private

  def set_uuid
    self.uuid ||= SecureRandom.uuid
  end
end
