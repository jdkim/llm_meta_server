class LlmApiKey < ApplicationRecord
  belongs_to :user

  validates :uuid, presence: true, uniqueness: true
  validates :llm_type, presence: true
  validates :encrypted_api_key, presence: true
  validates :description, length: { maximum: 255 }, allow_blank: true
end
