require "rails_helper"

RSpec.describe CreditTransaction, type: :model do
  let(:user) { User.create!(email: "u@example.com", google_id: "g1") }

  describe "validations" do
    it "is valid for a positive signup_grant" do
      tx = described_class.new(user: user, kind: "signup_grant", amount_cents: 3000)
      expect(tx).to be_valid
    end

    it "rejects a negative signup_grant" do
      tx = described_class.new(user: user, kind: "signup_grant", amount_cents: -100)
      expect(tx).not_to be_valid
      expect(tx.errors[:amount_cents]).to include("must be positive for signup_grant")
    end

    it "is valid for a positive admin_grant" do
      admin = User.create!(email: "a@example.com", google_id: "g2")
      tx = described_class.new(user: user, granted_by: admin, kind: "admin_grant", amount_cents: 500)
      expect(tx).to be_valid
    end

    it "is valid for a negative usage" do
      tx = described_class.new(user: user, kind: "usage", amount_cents: -42, model: "claude-sonnet-4-6")
      expect(tx).to be_valid
    end

    it "rejects a positive usage" do
      tx = described_class.new(user: user, kind: "usage", amount_cents: 42)
      expect(tx).not_to be_valid
      expect(tx.errors[:amount_cents]).to include("must be negative for usage")
    end

    it "allows either sign on adjustment" do
      expect(described_class.new(user: user, kind: "adjustment", amount_cents: 100)).to be_valid
      expect(described_class.new(user: user, kind: "adjustment", amount_cents: -100)).to be_valid
    end

    it "rejects zero amount" do
      tx = described_class.new(user: user, kind: "adjustment", amount_cents: 0)
      expect(tx).not_to be_valid
    end

    it "rejects unknown kind" do
      tx = described_class.new(user: user, kind: "bogus", amount_cents: 100)
      expect(tx).not_to be_valid
      expect(tx.errors[:kind]).to include("is not included in the list")
    end
  end

  describe "scopes" do
    before do
      described_class.create!(user: user, kind: "signup_grant", amount_cents: 3000)
      described_class.create!(user: user, kind: "admin_grant",  amount_cents: 1000)
      described_class.create!(user: user, kind: "usage",        amount_cents: -250, model: "claude-haiku-4-5")
    end

    it ".grants returns only positive grant rows" do
      expect(described_class.grants.pluck(:kind)).to contain_exactly("signup_grant", "admin_grant")
    end

    it ".usages returns only usage rows" do
      expect(described_class.usages.pluck(:amount_cents)).to eq([ -250 ])
    end
  end
end
