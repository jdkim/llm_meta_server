require "rails_helper"

RSpec.describe ProviderModelIndex do
  # Freeze `today` so freshness math is deterministic. Provider fetchers
  # default min_created to today.prev_month(12); tests pass an explicit
  # min_created where the assertion depends on it.
  let(:today) { Date.new(2026, 7, 20) }
  let(:one_year_ago) { today.prev_month(12) }

  describe ".openai" do
    let(:body) do
      {
        "data" => [
          { "id" => "gpt-5",              "created" => Date.new(2026, 5, 14).to_time.to_i },
          { "id" => "gpt-6",              "created" => Date.new(2026, 7, 15).to_time.to_i },
          { "id" => "gpt-5-2026-05-14",   "created" => Date.new(2026, 5, 14).to_time.to_i }, # dated snapshot
          { "id" => "gpt-4o",             "created" => Date.new(2024, 5, 1).to_time.to_i }, # too old
          { "id" => "gpt-5-mini:ft:acme", "created" => Date.new(2026, 6, 1).to_time.to_i }, # fine-tune
          { "id" => "text-embedding-3",   "created" => Date.new(2026, 6, 1).to_time.to_i }, # not frontier
          { "id" => "dall-e-3",           "created" => Date.new(2026, 6, 1).to_time.to_i }, # image gen
          { "id" => "whisper-1",          "created" => Date.new(2026, 6, 1).to_time.to_i }, # audio
          { "id" => "o3-pro",             "created" => Date.new(2026, 6, 15).to_time.to_i }, # o-series
          { "id" => "gpt-5-codex",        "created" => Date.new(2026, 6, 1).to_time.to_i }, # coding variant
          { "id" => "chatgpt-4o-latest",  "created" => Date.new(2026, 7, 5).to_time.to_i }
        ]
      }.to_json
    end

    before do
      stub_request(:get, "https://api.openai.com/v1/models")
        .with(headers: { "Authorization" => "Bearer sk-test" })
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
    end

    it "keeps only chat-frontier families (gpt-5+, o-series, chatgpt-*), drops legacy/embedding/audio/fine-tuned/dated" do
      results = described_class.openai("sk-test", min_created: one_year_ago)
      ids = results.map { |m| m[:id] }
      expect(ids).to contain_exactly("gpt-5", "gpt-6", "o3-pro", "chatgpt-4o-latest")
    end

    it "with include_dated: true, keeps dated snapshot ids alongside canonical names" do
      results = described_class.openai("sk-test", min_created: one_year_ago, include_dated: true)
      ids = results.map { |m| m[:id] }
      expect(ids).to include("gpt-5-2026-05-14")
    end

    it "sorts newest-first" do
      ids = described_class.openai("sk-test", min_created: one_year_ago).map { |m| m[:id] }
      expect(ids.first).to eq("gpt-6")
    end

    it "raises FetchError on non-200" do
      stub_request(:get, "https://api.openai.com/v1/models")
        .to_return(status: 401, body: '{"error":"unauthorized"}')
      expect { described_class.openai("bad-key") }
        .to raise_error(ProviderModelIndex::FetchError, /HTTP 401/)
    end
  end

  describe ".anthropic" do
    let(:body) do
      {
        "data" => [
          { "id" => "claude-opus-4-8",              "created_at" => "2026-07-01T00:00:00Z" },
          { "id" => "claude-sonnet-4-6",            "created_at" => "2025-11-01T00:00:00Z" },
          { "id" => "claude-3-5-sonnet-20241022",   "created_at" => "2026-06-01T00:00:00Z" }, # dated (YYYYMMDD)
          { "id" => "claude-2.1",                   "created_at" => "2023-11-21T00:00:00Z" }, # too old
          { "id" => "some-other",                   "created_at" => "2026-06-01T00:00:00Z" }  # not a claude-*
        ]
      }.to_json
    end

    before do
      stub_request(:get, "https://api.anthropic.com/v1/models")
        .with(headers: { "x-api-key" => "sk-ant-test", "anthropic-version" => "2023-06-01" })
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
    end

    it "keeps only claude-* models within the freshness window, newest first, drops dated snapshots" do
      results = described_class.anthropic("sk-ant-test", min_created: one_year_ago)
      ids = results.map { |m| m[:id] }
      expect(ids).to eq([ "claude-opus-4-8", "claude-sonnet-4-6" ])
    end

    it "with include_dated: true, keeps -YYYYMMDD snapshots" do
      results = described_class.anthropic("sk-ant-test", min_created: one_year_ago, include_dated: true)
      ids = results.map { |m| m[:id] }
      expect(ids).to include("claude-3-5-sonnet-20241022")
    end
  end

  describe ".google" do
    let(:body) do
      {
        "models" => [
          { "name" => "models/gemini-3.1-pro-preview" },
          { "name" => "models/gemini-3-flash-preview" },
          { "name" => "models/gemini-3.1-flash-lite" },        # GA
          { "name" => "models/gemini-3.1-flash-lite-preview" }, # redundant pin — GA sibling above
          { "name" => "models/gemini-2.5-pro-preview-05-06" }, # dated MM-DD
          { "name" => "models/gemini-exp-1206" },              # dated MMDD
          { "name" => "models/gemini-2.0-flash-001" },         # numeric pin -NNN
          { "name" => "models/gemini-embedding-001" },         # embedding
          { "name" => "models/gemini-robotics-er-1.5" },       # robotics-specialized
          { "name" => "models/gemini-3.1-pro-preview-customtools" }, # dev-eval variant
          { "name" => "models/aqa" },                          # not frontier
          { "name" => "models/text-embedding-004" },           # embedding
          { "name" => "models/imagen-3.0" },                   # image gen
          { "name" => "models/tunedModels/foo" }               # tuned
        ]
      }.to_json
    end

    before do
      stub_request(:get, "https://generativelanguage.googleapis.com/v1beta/models")
        .with(query: { key: "goog-test" })
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
    end

    it "strips the models/ prefix and keeps only gemini-* chat models, drops dated variants + redundant preview pins by default" do
      results = described_class.google("goog-test")
      ids = results.map { |m| m[:id] }
      # gemini-3.1-flash-lite-preview is dropped (GA sibling gemini-3.1-flash-lite exists).
      # gemini-3.1-pro-preview kept (no GA sibling).
      expect(ids).to contain_exactly("gemini-3-flash-preview", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite")
    end

    it "with include_dated: true, keeps -MM-DD, -MMDD, -NNN version-pins, and redundant preview pins" do
      results = described_class.google("goog-test", include_dated: true)
      ids = results.map { |m| m[:id] }
      expect(ids).to include("gemini-2.5-pro-preview-05-06", "gemini-exp-1206",
                              "gemini-2.0-flash-001", "gemini-3.1-flash-lite-preview")
    end

    it "leaves created_at nil since Google's list-models does not include it" do
      results = described_class.google("goog-test")
      expect(results.map { |m| m[:created_at] }.uniq).to eq([ nil ])
    end
  end
end
