class LlmApiKey < ApplicationRecord
  belongs_to :user

  validates :uuid, presence: true, uniqueness: true
  validates :llm_type, presence: true
  validates :encrypted_api_key, presence: true

  before_create :set_uuid
  before_destroy :clear_related_cache
  after_destroy :log_deletion

  def plain_api_key

  end

  private

  def set_uuid

  end

  #削除前にキャッシュをクリア
  def clear_related_cache

  end

  # 削除後のログ記録
  def log_deletion

  end
end
