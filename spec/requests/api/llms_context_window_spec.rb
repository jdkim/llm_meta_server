require "rails_helper"

# /api/llms is where a browser client learns what it may call, and it is the
# only call the widget already makes before a turn — so it is where a client
# can learn how much room a model has.
#
# Without the window a client budgets against fixed guesses: llm_meta_widget
# caps attached resources at 8 KB whatever the model, and caps tool results at
# nothing at all. A TogoMCP session reached 157,358 tokens against a
# 131,072-token model that way (2026-10-16).
RSpec.describe "GET /api/llms (context window)", type: :request do
  let(:user) { User.create!(email: "w@example.com", google_id: "g-window") }

  before do
    allow_any_instance_of(ApiController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApiController).to receive(:bearer_token).and_return("stub-token")
  end

  def families
    get "/api/llms"
    JSON.parse(response.body).fetch("llms")
  end

  it "reports the window for a hosted model" do
    model = LlmModel.active.joins(:llm).where.not(llms: { family: "ollama" }).first
    model.update!(max_input_tokens: 128_000)
    LlmModelMap.reload!

    hosted = families.find { |f| f["family"] == model.llm.family }
    entry  = hosted.fetch("models").find { |m| m["name"] == model.name }

    expect(entry["max_input_tokens"]).to eq(128_000)
  end

  it "reports nil rather than zero when the window is unknown" do
    # A client must be able to tell "no window recorded" from "a window of
    # zero" — the first means budget against nothing, the second is nonsense.
    model = LlmModel.active.joins(:llm).where.not(llms: { family: "ollama" }).first
    model.update!(max_input_tokens: nil)
    LlmModelMap.reload!

    hosted = families.find { |f| f["family"] == model.llm.family }
    entry  = hosted.fetch("models").find { |m| m["name"] == model.name }

    expect(entry).to have_key("max_input_tokens")
    expect(entry["max_input_tokens"]).to be_nil
  end

  # A local model has no column for a window — its window is whatever num_ctx
  # the catalog asks Ollama for. That is also the SMALLEST window in the
  # catalog (32,768 for medgemma against 200,000 for a hosted Claude), so it is
  # where a long tool result overflows first and where a client most needs the
  # number.
  it "reports a local model's num_ctx as its window" do
    ollama = families.find { |f| f["family"] == "ollama" }
    entry  = ollama.fetch("available_models").find { |m| m["value"] == "medgemma1-5-4b" }

    expect(entry["max_input_tokens"]).to eq(32_768)
  end

  # Ollama's own default when no num_ctx is set is 2048, which is useless for
  # tool work, so the catalog always sets one. A zero or missing value means
  # "not configured" and must read as unknown, never as a window of zero: a
  # zero window would make a client drop every tool result it ever receives.
  it "treats a zero num_ctx as unknown rather than as a window of zero" do
    allow(LlmModelMap).to receive(:catalog).and_return({
      "ollama" => { "zeroed" => { display_name: "Zeroed", defaults: { options: { num_ctx: 0 } } } }
    })
    entry = LlmModelMap.available_models_for("ollama").first

    expect(entry).not_to have_key("max_input_tokens")
  end

  it "reads num_ctx whether the catalog hash is symbol- or string-keyed" do
    allow(LlmModelMap).to receive(:catalog).and_return({
      "ollama" => { "strung" => { display_name: "Strung", defaults: { "options" => { "num_ctx" => 16_384 } } } }
    })
    entry = LlmModelMap.available_models_for("ollama").first

    expect(entry["max_input_tokens"]).to eq(16_384)
  end

  it "omits the field for a local model configured with no num_ctx" do
    allow(LlmModelMap).to receive(:catalog).and_return({
      "ollama" => { "bare" => { display_name: "Bare", defaults: {} } }
    })
    entry = LlmModelMap.available_models_for("ollama").first

    expect(entry).not_to have_key("max_input_tokens")
  end
end
