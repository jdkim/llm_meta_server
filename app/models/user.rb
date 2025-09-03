class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :omniauthable, omniauth_providers: %i[google_oauth2]

  # has_many :llm_api_keys, dependent: :destroy

  validates :email, presence: true, uniqueness: true

  def self.from_omniauth(auth)
  end

  # APIキーを追加
  def add_llm_apikey(llm_type, plain_api_key)
  end

  # APIキーを更新
  def update_llm_apikey(key_id, new_plain_api_key)
  end

  # APIキーを削除
  def remove_llm_apikey(key_id)
  end

  private

  # 関連データのクリーンアップ
  def cleanup_related_data(llm_api_key)
  end
end
