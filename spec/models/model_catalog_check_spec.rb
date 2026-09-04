require "rails_helper"

RSpec.describe ModelCatalogCheck do
  it "records a successful check with its diff" do
    check = described_class.record!(provider: "openai", new_in_provider: %w[gpt-9], missing_from_provider: [])

    expect(check).to be_ok
    expect(check).to be_actionable
    expect(check.candidate_ids).to eq(%w[gpt-9])
  end

  it "carries a reference price alongside a candidate when one was found" do
    check = described_class.record!(provider: "openai", new_in_provider: [
      { "api_id" => "gpt-9", "input" => 1.0, "output" => 2.0, "sources" => %w[litellm] }
    ])

    expect(check.candidate_ids).to eq(%w[gpt-9])
    expect(check.candidates.first["input"]).to eq(1.0)
  end

  it "still reads rows recorded before prices were attached" do
    check = described_class.record!(provider: "openai", new_in_provider: %w[old-style])

    expect(check.candidates).to eq([ { "api_id" => "old-style" } ])
  end

  it "records a failed check without losing the reason" do
    check = described_class.record!(provider: "google", error: "skipped: no stored google key")

    expect(check).not_to be_ok
    expect(check).not_to be_actionable
  end

  it "is not actionable when the catalog matches the provider" do
    expect(described_class.record!(provider: "anthropic")).not_to be_actionable
  end

  it "returns only the newest row per provider, newest first" do
    described_class.record!(provider: "openai").update!(checked_at: 3.days.ago)
    newest = described_class.record!(provider: "openai")
    newest.update!(checked_at: 1.hour.ago)
    described_class.record!(provider: "google").update!(checked_at: 2.days.ago)

    latest = described_class.latest_per_provider

    expect(latest.map(&:provider)).to eq(%w[openai google])
    expect(latest.first.id).to eq(newest.id)
  end

  describe "#pending_candidates" do
    # A recorded check is a snapshot. Without filtering, a model added after
    # the check keeps showing as "available but not in the catalog", which
    # reads as though adding it had failed.
    let(:check) do
      described_class.record!(provider: "openai", new_in_provider: [
        { "api_id" => "gpt-9", "input" => 1.0, "output" => 2.0 },
        { "api_id" => "gpt-10" }
      ])
    end

    it "drops candidates the catalog has since gained" do
      expect(check.pending_candidates(Set["gpt-9"]).map { |c| c["api_id"] }).to eq(%w[gpt-10])
    end

    it "keeps everything when the catalog has none of them" do
      expect(check.pending_candidates(Set.new).size).to eq(2)
    end

    it "is empty once all have been added" do
      expect(check.pending_candidates(Set["gpt-9", "gpt-10"])).to be_empty
    end
  end
end
