require "rails_helper"

# The server's own credential, used when an anonymous caller picks a model the
# catalog marks free_access. Ollama needs no key; this exists for hosted models
# we choose to give away.
RSpec.describe "LlmApiKey.house_key" do
  let(:owner) { User.create!(email: "house@example.com", google_id: "g-house") }
  let!(:key) do
    LlmApiKey.create!(user: owner, llm_type: "bedrock", description: "house",
                      encryptable_api_key: EncryptableApiKey.new(plain_api_key: "secret"))
  end

  around do |example|
    was = ENV["HOUSE_LLM_API_KEY_UUID"]
    example.run
    was.nil? ? ENV.delete("HOUSE_LLM_API_KEY_UUID") : ENV["HOUSE_LLM_API_KEY_UUID"] = was
  end

  it "is nil when no house key is configured — free access must not silently fall back" do
    ENV.delete("HOUSE_LLM_API_KEY_UUID")
    expect(LlmApiKey.house_key).to be_nil
  end

  it "is nil when the configured uuid names nothing (revoked, wrong env)" do
    ENV["HOUSE_LLM_API_KEY_UUID"] = SecureRandom.uuid
    expect(LlmApiKey.house_key).to be_nil
  end

  it "resolves the row named by the environment" do
    ENV["HOUSE_LLM_API_KEY_UUID"] = key.uuid
    expect(LlmApiKey.house_key).to eq(key)
  end

  # A revoked key has to stop working on the next request, not the next deploy.
  it "is not memoized across calls" do
    ENV["HOUSE_LLM_API_KEY_UUID"] = key.uuid
    expect(LlmApiKey.house_key).to eq(key)
    key.destroy!
    expect(LlmApiKey.house_key).to be_nil
  end
end

RSpec.describe "LlmRbFacade#create_llm_client with no user key" do
  let(:model_id) { "openai.gpt-oss-120b-1:0" }

  before { allow(LlmModelMap).to receive(:ollama_model?).with(model_id).and_return(false) }

  it "uses the house key for a free_access model" do
    allow(LlmModelMap).to receive(:free_access_model?).with(model_id).and_return(true)
    house = double("LlmApiKey", llm_rb_method: :bedrock,
                   encryptable_api_key: double(plain_api_key: "house-secret"))
    allow(LlmApiKey).to receive(:house_key).and_return(house)

    client = LlmRbFacade.send(:create_llm_client, nil, model_id)

    expect(client).to be_a(BedrockClient)
  end

  # The failure that matters: free access configured but no key provisioned.
  # Better a clear LlmApiKeyRequiredError than NoMethodError on nil.
  it "raises the typed error when free_access is on but no house key exists" do
    allow(LlmModelMap).to receive(:free_access_model?).with(model_id).and_return(true)
    allow(LlmApiKey).to receive(:house_key).and_return(nil)

    expect { LlmRbFacade.send(:create_llm_client, nil, model_id) }
      .to raise_error(LlmApiKeyRequiredError)
  end

  # A model that is NOT free_access must never reach the server's wallet.
  it "does not hand the house key to a non-free model" do
    allow(LlmModelMap).to receive(:free_access_model?).with(model_id).and_return(false)
    allow(LlmApiKey).to receive(:house_key).and_return(double("should not be used"))

    expect { LlmRbFacade.send(:create_llm_client, nil, model_id) }
      .to raise_error(LlmApiKeyRequiredError)
  end
end
