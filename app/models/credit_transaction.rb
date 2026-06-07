class CreditTransaction < ApplicationRecord
  belongs_to :user
  belongs_to :granted_by, class_name: "User", optional: true

  KINDS       = %w[signup_grant admin_grant usage refund adjustment].freeze
  GRANT_KINDS = %w[signup_grant admin_grant refund].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :amount_cents, presence: true, numericality: { only_integer: true, other_than: 0 }
  validate  :sign_matches_kind

  scope :grants, -> { where(kind: GRANT_KINDS) }
  scope :usages, -> { where(kind: "usage") }

  private

  # Grants must be positive, usages must be negative. Adjustments may
  # be either sign — they're a free-form escape hatch for corrections.
  def sign_matches_kind
    case kind
    when *GRANT_KINDS
      errors.add(:amount_cents, "must be positive for #{kind}") if amount_cents.to_i <= 0
    when "usage"
      errors.add(:amount_cents, "must be negative for usage") if amount_cents.to_i >= 0
    end
  end
end
