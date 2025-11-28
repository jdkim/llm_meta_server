class LlmModel < ApplicationRecord
  belongs_to :llm
  has_many :llm_api_keys, through: :llm
  validates :name, presence: true

  def as_json
    {
      name: name,
      display_name: display_name,
      created_at: created_at,
      updated_at: updated_at
    }
  end
end
