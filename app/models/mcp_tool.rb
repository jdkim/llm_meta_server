class McpTool < ApplicationRecord
  belongs_to :mcp_server

  validates :name, presence: true, uniqueness: { scope: :mcp_server_id }
  validates :input_schema, presence: true

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  def as_json(options = {})
    super({ only: %i[id name description input_schema active] }.merge(options))
  end
end
