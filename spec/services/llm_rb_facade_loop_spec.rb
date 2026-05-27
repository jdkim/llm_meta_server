require "rails_helper"

# Focused specs for behaviors added recently in LlmRbFacade: the streaming
# tool-call iteration loop, with_image_payload tmpfile wrapping, and the
# Anthropic max_tokens default.
RSpec.describe LlmRbFacade do
  let(:llm_client) { instance_double("LLM::Provider") }
  let(:model_id) { "qwen3.5:4b" }

  before do
    allow(LlmModelMap).to receive(:ollama_model?).and_return(true)
    allow(LLM).to receive(:ollama).and_return(llm_client)
    # Non-Gemini client → no native server tools attached.
    allow(llm_client).to receive_message_chain(:class, :name).and_return("LLM::Ollama")
  end

  describe ".stream! with tools (loop behavior)" do
    let(:session) { instance_double("LLM::Session") }
    let(:sink) { Class.new { def <<(x); (@buf ||= +"") << x.to_s end; def buf; @buf || ""; end }.new }
    let(:tool) { double("Function", call: double("Return", value: { "result" => "ok" }, name: "do_thing")) }

    before do
      allow(LLM::Session).to receive(:new).and_return(session)
      allow(session).to receive(:extract_tool_calls).and_return([])
    end

    it "loops until the model emits text content (no more tool calls)" do
      # Turn 1: tool call. Turn 2: empty (still wanting another tool). Turn 3: text.
      call_count = 0
      empty_response = instance_double("Response", choices: [ instance_double("Choice", content: "") ], body: nil)
      text_response  = instance_double("Response", choices: [ instance_double("Choice", content: "final answer") ], body: nil)

      # Turn 1 + iter 1 + iter 2 = 3 chats. Functions are present after chats 1
      # and 2 (the loop sees them), and absent after chat 3 (loop exits).
      allow(session).to receive(:functions) { call_count < 3 ? [ tool ] : [] }
      allow(session).to receive(:chat) do |_, **|
        call_count += 1
        case call_count
        when 1 then empty_response
        when 2 then empty_response
        else text_response
        end
      end

      result = described_class.stream!(model_id, "go", sink: sink, tools: [ tool ])

      # 3 chat calls: turn 1 (synchronous) + 2 streamed iterations.
      expect(call_count).to eq(3)
      expect(result).to be_a(String).or be_a(Hash)
    end

    it "stops at MAX_TOOL_ITERATIONS and writes a fallback notice to the sink" do
      stuck_response = instance_double("Response", choices: [ instance_double("Choice", content: "") ], body: nil)
      allow(session).to receive(:functions).and_return([ tool ])
      allow(session).to receive(:chat).and_return(stuck_response)

      described_class.stream!(model_id, "loop", sink: sink, tools: [ tool ])

      # Turn 1 + 5 iterations = 6 chat calls total.
      expect(session).to have_received(:chat).exactly(6).times
      expect(sink.buf).to include("stopped after")
      expect(sink.buf).to include("tool rounds")
    end
  end

  describe ".stream! with image" do
    let(:session) { instance_double("LLM::Session") }
    let(:response) { instance_double("Response", choices: [ instance_double("Choice", content: "ok") ], body: nil) }
    let(:sink) { Class.new { def <<(x); (@buf ||= +"") << x.to_s; self; end }.new }

    before do
      allow(LLM::Session).to receive(:new).and_return(session)
    end

    it "wraps the image as an LLM::Object(:local_file) and passes [object, prompt] to session.chat" do
      captured = nil
      allow(session).to receive(:chat) { |content, **| captured = content; response }

      described_class.stream!(model_id, "describe", sink: sink,
                              image: { mime: "image/png", data_b64: Base64.strict_encode64("\x89PNG\r\n\x1a\n") })

      expect(captured).to be_an(Array)
      expect(captured.first).to be_an(LLM::Object)
      expect(captured.first.kind).to eq(:local_file)
      expect(captured.first.value).to be_an(LLM::File)
      expect(captured.first.value.mime_type).to eq("image/png")
      expect(captured.last).to eq("describe")
    end

    it "passes the bare prompt when no image is provided" do
      captured = nil
      allow(session).to receive(:chat) { |content, **| captured = content; response }

      described_class.stream!(model_id, "no image", sink: sink)
      expect(captured).to eq("no image")
    end
  end

  describe "Anthropic max_tokens default" do
    let(:anthropic_key) {
      user = User.create!(email: "u@example.com", google_id: "g-anthropic")
      user.llm_api_keys.create!(llm_type: "anthropic", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-anth"))
    }
    let(:session) { instance_double("LLM::Session") }
    let(:response) { instance_double("Response", choices: [ instance_double("Choice", content: "ok") ], body: nil) }
    let(:sink) { Class.new { def <<(x); self; end }.new }

    before do
      # Stub AWS KMS to avoid real network calls when persisting the LlmApiKey.
      allow_any_instance_of(ApiKeyEncrypter).to receive(:encrypt).and_return("ENC")
      allow_any_instance_of(ApiKeyDecrypter).to receive(:decrypt).and_return("sk-anth")

      allow(LlmModelMap).to receive(:ollama_model?).and_return(false)
      allow(LLM).to receive(:anthropic).and_return(llm_client)
      allow(llm_client).to receive_message_chain(:class, :name).and_return("LLM::Anthropic")
      allow(LLM::Session).to receive(:new).and_return(session)
      allow(session).to receive(:chat).and_return(response)
    end

    it "applies max_tokens=8192 default for Anthropic when not provided" do
      described_class.stream!("claude-opus-4-7", "hi", sink: sink, llm_api_key: anthropic_key)
      expect(LLM::Session).to have_received(:new).with(
        llm_client, hash_including(max_tokens: 8192)
      )
    end

    it "does not override an explicit max_tokens" do
      described_class.stream!("claude-opus-4-7", "hi", sink: sink, llm_api_key: anthropic_key,
                              generation_params: { max_tokens: 2000 })
      expect(LLM::Session).to have_received(:new).with(
        llm_client, hash_including(max_tokens: 2000)
      )
    end
  end
end
