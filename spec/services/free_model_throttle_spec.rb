require "rails_helper"

# A free model is free to the visitor, not to us. gpt-oss on Bedrock bills the
# house key on an endpoint reachable anonymously, so this bounds how fast one
# caller can spend it.
RSpec.describe FreeModelThrottle do
  let(:free_model) { "openai.gpt-oss-120b-1:0" }
  let(:paid_model) { "anthropic.claude-opus-4-7" }

  # The test env uses :null_store, which cannot count — with it, this guard
  # silently never fires. Swap in a real store so these examples measure the
  # throttle rather than the cache.
  around do |example|
    was = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = was
  end

  before do
    Rails.cache.clear
    allow(LlmModelMap).to receive(:free_access_model?).with(free_model).and_return(true)
    allow(LlmModelMap).to receive(:free_access_model?).with(paid_model).and_return(false)
  end

  def call(model_id: free_model, llm_api_key: nil, user: nil, origin: "https://site.example", ip: "203.0.113.1")
    described_class.check!(model_id:, llm_api_key:, user:, origin:, ip:)
  end

  it "allows up to the limit and then refuses" do
    described_class::LIMIT.times { expect { call }.not_to raise_error }
    expect { call }.to raise_error(described_class::Exceeded, /Add your own API key/)
  end

  it "never throttles a caller paying with their own key" do
    (described_class::LIMIT + 5).times do
      expect { call(llm_api_key: double("LlmApiKey")) }.not_to raise_error
    end
  end

  it "ignores models that are not free — those bill the caller, not us" do
    (described_class::LIMIT + 5).times { expect { call(model_id: paid_model) }.not_to raise_error }
  end

  # ONE bucket across all free models: the wallet is shared, so splitting the
  # budget per model would multiply the ceiling by the size of the catalog.
  it "counts every free model into a single bucket" do
    other = "ollama.qwen"
    allow(LlmModelMap).to receive(:free_access_model?).with(other).and_return(true)

    (described_class::LIMIT - 1).times { call }
    expect { call(model_id: other) }.not_to raise_error   # the 30th, different model
    expect { call(model_id: other) }.to raise_error(described_class::Exceeded)
  end

  describe "who shares a budget" do
    it "separates one origin from another" do
      described_class::LIMIT.times { call(origin: "https://a.example") }
      expect { call(origin: "https://b.example") }.not_to raise_error
    end

    it "gives a signed-in user their own budget, so a busy site cannot exhaust it" do
      user = double("User", id: 7)
      described_class::LIMIT.times { call(origin: "https://busy.example") }
      expect { call(user: user, origin: "https://busy.example") }.not_to raise_error
    end

    it "falls back to IP when a request carries no Origin" do
      described_class::LIMIT.times { call(origin: nil, ip: "198.51.100.9") }
      expect { call(origin: nil, ip: "198.51.100.9") }.to raise_error(described_class::Exceeded)
      expect { call(origin: nil, ip: "198.51.100.10") }.not_to raise_error
    end
  end

  # The guard standing in front of a paid endpoint must never fail silently.
  describe "when the cache cannot count" do
    around do |example|
      was = Rails.cache
      Rails.cache = ActiveSupport::Cache::NullStore.new
      example.run
      Rails.cache = was
    end

    it "keeps serving but logs an error naming the store" do
      expect(Rails.logger).to receive(:error).at_least(:once) do |msg|
        expect(msg).to include("NullStore", "NOT being throttled")
      end
      expect { call }.not_to raise_error
    end
  end
end
