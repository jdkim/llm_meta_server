class LlmModel < ApplicationRecord
  belongs_to :llm
  # has_many :llm_api_keys, through: :llm
  validates :name, presence: true
end
