require "rails_helper"

# Ollama is the odd provider out: local, keyless, and its /api/tags lists
# exactly what an operator pulled onto the box rather than a vendor catalog.
RSpec.describe ProviderModelIndex, ".ollama" do
  # Endpoint resolution — including the OLLAMA_HOST collision with the ollama
  # CLI — is covered in spec/services/ollama_endpoint_spec.rb.
  let(:body) do
    {
      "models" => [
        { "name" => "qwen3.8:latest",       "modified_at" => "2026-09-04T10:00:00Z" },
        { "name" => "qwen3.6:35b",          "modified_at" => "2026-07-01T10:00:00Z" },
        { "name" => "nomic-embed-text",     "modified_at" => "2026-08-01T10:00:00Z" },
        { "name" => "bge-reranker",         "modified_at" => "2026-08-02T10:00:00Z" }
      ]
    }.to_json
  end

  before do
    stub_request(:get, %r{/api/tags}).to_return(status: 200, body: body,
                                                headers: { "Content-Type" => "application/json" })
  end

  it "lists the local chat models, newest first" do
    expect(described_class.ollama.map { |m| m[:id] }).to eq([ "qwen3.8:latest", "qwen3.6:35b" ])
  end

  it "reads modified_at as the date" do
    expect(described_class.ollama.first[:created_at]).to eq(Date.new(2026, 9, 4))
  end

  it "drops embedding and reranking models — they are not chat models" do
    ids = described_class.ollama.map { |m| m[:id] }

    expect(ids).not_to include("nomic-embed-text", "bge-reranker")
  end

  it "does not apply a freshness cutoff — a pulled model is one the operator wants" do
    # qwen3.6:35b is older than the 12-month lookback used for cloud providers
    # would be relative to a distant future date; it must still be listed.
    expect(described_class.ollama(nil, min_created: Date.new(2030, 1, 1)).map { |m| m[:id] })
      .to include("qwen3.6:35b")
  end

  it "needs no API key" do
    expect { described_class.ollama }.not_to raise_error
  end

  it "raises FetchError when the server is unreachable" do
    stub_request(:get, %r{/api/tags}).to_return(status: 500, body: "boom")

    expect { described_class.ollama }.to raise_error(described_class::FetchError, /HTTP 500/)
  end

  it "exposes the same ids through all_ids, unfiltered" do
    expect(described_class.all_ids("ollama", nil)).to include("nomic-embed-text")
  end
end

RSpec.describe ModelCheckKey, "keyless providers" do
  it "reports ollama as ready without a stored key" do
    result = described_class.for("ollama")

    expect(result).to be_present
    expect(result.source).to eq(:not_required)
  end

  it "still requires a key for cloud providers" do
    expect(described_class.for("openai").source).not_to eq(:not_required)
  end
end

# The check ran and stored ollama candidates, but the admin page filtered the
# row out again: latest_per_provider allowlists PROVIDERS, and ollama was not
# in it. The result was a feature that looked completely inert.
RSpec.describe ModelCatalogCheck, "provider coverage" do
  it "includes ollama, so its results are not filtered out of the admin page" do
    expect(described_class::PROVIDERS).to include("ollama")
  end

  it "surfaces a recorded ollama check through latest_per_provider" do
    described_class.record!(provider: "ollama",
                            new_in_provider: [ { "api_id" => "qwen3.8:27b" } ])

    expect(described_class.latest_per_provider.map(&:provider)).to include("ollama")
  end

  it "still excludes the pricing pseudo-provider, which has its own panel" do
    described_class.record_pricing_drift!([])

    expect(described_class.latest_per_provider.map(&:provider)).not_to include("pricing")
  end
end
