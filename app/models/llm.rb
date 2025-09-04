class Llm < ApplicationRecord
  # has_many :llm_api_keys, dependent: :destroy
  # has_many :llm_models, dependent: :destroy

  validates :name, presence: true, uniqueness: true
end
