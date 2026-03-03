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

  def as_json(options = {})
    super({ only: %i[uuid name url active server_name server_version protocol_version last_fetched_at last_error] }.merge(options))
      .merge(
        "tools" => mcp_tools.map(&:as_json)
      )
  end

  private

  def set_uuid
    self.uuid ||= SecureRandom.uuid
  end
end
