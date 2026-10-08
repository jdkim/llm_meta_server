require "rails_helper"

# Bedrock reached through its OpenAI-compatible endpoint. The two things that
# differ from stock OpenAI are the host and the base path; everything else is
# inherited on purpose, so the tests pin exactly those two and the inheritance.
RSpec.describe BedrockClient do
  around do |example|
    original = ENV.to_hash.slice("BEDROCK_REGION", "AWS_REGION")
    example.run
    ENV["BEDROCK_REGION"] = original["BEDROCK_REGION"]
    ENV["AWS_REGION"]     = original["AWS_REGION"]
    ENV.delete("BEDROCK_REGION") if original["BEDROCK_REGION"].nil?
    ENV.delete("AWS_REGION")     if original["AWS_REGION"].nil?
  end

  describe "the endpoint" do
    it "serves the OpenAI surface under /openai/v1, not /v1" do
      # bedrock-runtime's path differs from every other OpenAI-compatible host;
      # getting this wrong 404s on every call.
      expect(described_class.new(key: "k").__send__(:completions_path))
        .to eq("/openai/v1/chat/completions")
    end

    it "inherits the OpenAI wire format rather than reimplementing it" do
      expect(described_class.new(key: "k")).to be_a(LLM::OpenAI)
    end
  end

  # These assert the CONSTRUCTED CLIENT's URL, not the class method. An earlier
  # version checked `described_class.host` only, and deleting the `initialize`
  # override — the sole thing that points the client at Bedrock — still passed
  # every test. The failure that would have shipped is the worst kind: requests
  # going to api.openai.com carrying a Bedrock key.
  def built_host(**env)
    env.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    described_class.new(key: "k").__send__(:base_uri).host
  end

  describe "where requests actually go" do
    it "follows AWS_REGION, so inference lands where KMS already is" do
      expect(built_host(BEDROCK_REGION: nil, AWS_REGION: "ap-northeast-1"))
        .to eq("bedrock-runtime.ap-northeast-1.amazonaws.com")
    end

    it "lets BEDROCK_REGION override it" do
      expect(built_host(AWS_REGION: "ap-northeast-1", BEDROCK_REGION: "us-east-1"))
        .to eq("bedrock-runtime.us-east-1.amazonaws.com")
    end

    it "falls back to Tokyo when neither is set" do
      expect(built_host(BEDROCK_REGION: nil, AWS_REGION: nil))
        .to eq("bedrock-runtime.ap-northeast-1.amazonaws.com")
    end

    it "never falls through to OpenAI's host" do
      expect(built_host(BEDROCK_REGION: nil, AWS_REGION: nil)).not_to include("openai.com")
    end
  end

  describe "provider selection" do
    it "maps the bedrock llm_type to the :bedrock factory symbol" do
      expect(LlmApiKey::LLM_SERVICES["bedrock"]).to eq(:bedrock)
    end
  end
end
