class McpTool < ApplicationRecord
  belongs_to :mcp_server

  validates :name, presence: true, uniqueness: { scope: :mcp_server_id }
  validates :input_schema, presence: true

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  # Resolve tool_ids the given viewer is allowed to invoke. Returns active
  # tools belonging to servers visible to the viewer — i.e., the viewer's
  # own + active public servers from other users. Replaces the previous
  # User#find_mcp_tools, which scoped to ownership only.
  def self.lookup(tool_ids, viewer:)
    return none if tool_ids.blank?

    active
      .where(id: tool_ids)
      .joins(:mcp_server)
      .merge(McpServer.active)
      .merge(McpServer.visible_to(viewer))
      .includes(:mcp_server)
  end

  def as_json(options = {})
    super({ only: %i[id name description input_schema active annotations] }.merge(options))
  end

  # MCP 2025-03-26 tool annotations. Each hint is optional; a missing hint
  # means "no claim either way", not false — surface only when explicitly set.
  # See modelcontextprotocol.io/specification for the semantics.
  def title
    annotations_hash["title"]
  end

  def read_only_hint?
    annotations_hash["readOnlyHint"] == true
  end

  def destructive_hint?
    annotations_hash["destructiveHint"] == true
  end

  def idempotent_hint?
    annotations_hash["idempotentHint"] == true
  end

  def open_world_hint?
    annotations_hash["openWorldHint"] == true
  end

  private

  def annotations_hash
    annotations.is_a?(Hash) ? annotations : {}
  end
end
