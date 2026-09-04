require "rails_helper"

RSpec.describe ModelCheckKey do
  VARS = %w[MODEL_CHECK_OPENAI_KEY MODEL_CHECK_ANTHROPIC_KEY MODEL_CHECK_GOOGLE_KEY].freeze

  # dotenv loads .env in the test environment too, and that file carries real
  # MODEL_CHECK_* keys. Without this the examples below would read whichever
  # live key happened to be present — and print it on failure. Save, clear,
  # restore around every example so the environment is explicit.
  around do |example|
    saved = VARS.to_h { |v| [ v, ENV[v] ] }
    VARS.each { |v| ENV.delete(v) }
    example.run
  ensure
    saved.each { |v, val| val.nil? ? ENV.delete(v) : ENV[v] = val }
  end

  def make_key(email:, llm_type:, plain:)
    user = User.create!(email: email, google_id: "g-#{email}")
    rec  = LlmApiKey.new(user: user, llm_type: llm_type, description: "d")
    rec.encryptable_api_key = EncryptableApiKey.new(plain_api_key: plain)
    rec.save!
    rec
  end

  it "prefers an explicit env override so a throwaway key can be used" do
    make_key(email: "a@example.com", llm_type: "openai", plain: "sk-stored")
    ENV["MODEL_CHECK_OPENAI_KEY"] = "sk-env"

    result = described_class.for("openai")

    expect(result.key).to eq("sk-env")
    expect(result.source).to eq(:env)
  end

  it "falls back to a stored key so the check needs no setup" do
    make_key(email: "a@example.com", llm_type: "openai", plain: "sk-stored")

    result = described_class.for("openai")

    expect(result.key).to eq("sk-stored")
    expect(result.source).to eq(:stored)
  end

  it "prefers a super_user's key over an ordinary user's" do
    make_key(email: "ordinary@example.com", llm_type: "openai", plain: "sk-ordinary")
    make_key(email: "admin@example.com",    llm_type: "openai", plain: "sk-admin")
    allow(User).to receive(:super_user_emails).and_return([ "admin@example.com" ])

    expect(described_class.for("openai").key).to eq("sk-admin")
  end

  it "reports missing rather than raising when no key exists" do
    result = described_class.for("anthropic")

    expect(result).not_to be_present
    expect(result.source).to eq(:missing)
  end

  it "degrades to an error result when decryption fails, so other providers still run" do
    make_key(email: "a@example.com", llm_type: "google", plain: "sk-x")
    allow_any_instance_of(ApiKeyDecrypter).to receive(:decrypt).and_raise(RuntimeError, "kms down")

    result = described_class.for("google")

    expect(result).not_to be_present
    expect(result.source).to eq(:error)
    expect(result.detail).to include("kms down")
  end
end
