require "rails_helper"

# Focused specs for behaviors added recently in LlmRbFacade: the streaming
# tool-call iteration loop, with_image_payload tmpfile wrapping, and the
# Anthropic max_tokens default.
RSpec.describe LlmRbFacade do
  let(:llm_client) { instance_double("LLM::Provider") }
  let(:model_id) { "qwen3.6:35b-fast" }

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

      # Turn 1 + MAX_TOOL_ITERATIONS iterations. Compute the expected count
      # from the constant so bumping the cap doesn't require a numeric edit
      # here — the intent is "one more than the cap", not "6". The constant
      # lives on the singleton class (defined inside `class << self`).
      cap = described_class.singleton_class::MAX_TOOL_ITERATIONS
      expect(session).to have_received(:chat).exactly(cap + 1).times
      expect(sink.buf).to include("stopped after")
      expect(sink.buf).to include("tool rounds")
    end

    # A thinking model can finish a tool round having reasoned at length and
    # written nothing: qwen3.8 read TogoMCP's usage guide, produced 2,255
    # characters of reasoning, then ended its turn. The bubble was empty with
    # no explanation, which is indistinguishable from a failure.
    it "explains itself when the loop ends with reasoning but no answer" do
      empty = instance_double("Response", choices: [ instance_double("Choice", content: "") ], body: nil)
      call_count = 0
      allow(session).to receive(:chat) { call_count += 1; empty }
      allow(session).to receive(:functions) { call_count >= 2 ? [] : [ tool ] }

      described_class.stream!("qwen3.8:27b", "hi", sink: sink, llm_api_key: nil,
                              tools: [ { "name" => "t", "description" => "d", "inputSchema" => {} } ])

      expect(sink.buf).to include("ended its turn without writing an answer")
    end

    it "stays quiet when the model did answer" do
      answered = instance_double("Response", choices: [ instance_double("Choice", content: "here you go") ], body: nil)
      call_count = 0
      # Turn 2 is streamed, so the real session writes the answer to the sink
      # as it arrives; the notice keys off what actually reached the client.
      allow(session).to receive(:chat) do |_input, **kwargs|
        call_count += 1
        kwargs[:stream] << "here you go" if kwargs[:stream].respond_to?(:<<) && call_count >= 2
        answered
      end
      allow(session).to receive(:functions) { call_count >= 2 ? [] : [ tool ] }

      described_class.stream!("qwen3.8:27b", "hi", sink: sink, llm_api_key: nil,
                              tools: [ { "name" => "t", "description" => "d", "inputSchema" => {} } ])

      expect(sink.buf).not_to include("ended its turn without writing an answer")
    end

    it "explains itself when turn 1 answers nothing and calls nothing" do
      empty = instance_double("Response", choices: [ instance_double("Choice", content: "") ], body: nil)
      allow(session).to receive(:chat).and_return(empty)
      allow(session).to receive(:functions).and_return([])

      described_class.stream!("qwen3.8:27b", "hi", sink: sink, llm_api_key: nil,
                              tools: [ { "name" => "t", "description" => "d", "inputSchema" => {} } ])

      expect(sink.buf).to include("ended its turn without writing an answer")
    end

    it "writes a truncation notice when Ollama stops on the num_predict cap" do
      # Ollama reports `done_reason: "length"` on the final chunk when it hits
      # options.num_predict. Without a notice the answer just stops mid-sentence.
      capped = double("Response",
                      choices: [ double("Choice", content: "half an ans") ],
                      body: nil, done_reason: "length")
      allow(session).to receive(:functions).and_return([])
      allow(session).to receive(:chat).and_return(capped)

      described_class.stream!(model_id, "go", sink: sink, tools: [ tool ])

      expect(sink.buf).to include("truncated at the output limit")
      expect(sink.buf).to include("num_predict")
    end

    it "writes no truncation notice when the model stopped on its own" do
      done = double("Response",
                    choices: [ double("Choice", content: "a full answer") ],
                    body: nil, done_reason: "stop")
      allow(session).to receive(:functions).and_return([])
      allow(session).to receive(:chat).and_return(done)

      described_class.stream!(model_id, "go", sink: sink, tools: [ tool ])

      expect(sink.buf).not_to include("truncated at the output limit")
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

    it "does NOT inject `thinking` at the facade layer (each Claude model declares its own in the catalog)" do
      # Anthropic models accept different `thinking.type` values across
      # the catalog (Opus/Sonnet take adaptive; Haiku rejects it). The
      # facade stays out of it; per-model `defaults:` blocks in
      # llm_models.yml supply the right shape via LlmModelMap.defaults_for
      # (merged in by the controller before reaching the facade).
      described_class.stream!("claude-opus-4-7", "hi", sink: sink, llm_api_key: anthropic_key)
      expect(LLM::Session).to have_received(:new).with(
        llm_client, satisfy { |params| !params.key?(:thinking) }
      )
    end

    it "preserves any caller-supplied thinking config (catalog defaults flow in via the controller)" do
      described_class.stream!("claude-opus-4-7", "hi", sink: sink, llm_api_key: anthropic_key,
                              generation_params: { thinking: { type: "adaptive" } })
      expect(LLM::Session).to have_received(:new).with(
        llm_client, hash_including(thinking: { type: "adaptive" })
      )
    end

    it "preserves any caller-supplied output_config (no facade default for this either)" do
      described_class.stream!("claude-opus-4-7", "hi", sink: sink, llm_api_key: anthropic_key,
                              generation_params: { output_config: { effort: "high" } })
      expect(LLM::Session).to have_received(:new).with(
        llm_client, hash_including(output_config: { effort: "high" })
      )
    end

    it "preserves a user-supplied thinking config (e.g. type: 'disabled' to opt out)" do
      described_class.stream!("claude-opus-4-7", "hi", sink: sink, llm_api_key: anthropic_key,
                              generation_params: { thinking: { type: "disabled" } })
      expect(LLM::Session).to have_received(:new).with(
        llm_client, hash_including(thinking: { type: "disabled" })
      )
    end
  end

  describe "Gemini thinking-mode default" do
    let(:google_key) {
      user = User.create!(email: "u@example.com", google_id: "g-google")
      user.llm_api_keys.create!(llm_type: "google", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "g-key"))
    }
    let(:session) { instance_double("LLM::Session") }
    let(:response) { instance_double("Response", choices: [ instance_double("Choice", content: "ok") ], body: nil) }
    let(:sink) { Class.new { def <<(x); self; end }.new }

    before do
      allow_any_instance_of(ApiKeyEncrypter).to receive(:encrypt).and_return("ENC")
      allow_any_instance_of(ApiKeyDecrypter).to receive(:decrypt).and_return("g-key")
      allow(LlmModelMap).to receive(:ollama_model?).and_return(false)
      allow(LLM).to receive(:gemini).and_return(llm_client)
      allow(llm_client).to receive_message_chain(:class, :name).and_return("LLM::Gemini")
      allow(LLM::Session).to receive(:new).and_return(session)
      allow(session).to receive(:chat).and_return(response)
    end

    it "injects generationConfig.thinkingConfig.includeThoughts: true for google by default" do
      described_class.stream!("gemini-3-flash", "hi", sink: sink, llm_api_key: google_key)
      expect(LLM::Session).to have_received(:new).with(
        llm_client, hash_including(generationConfig: hash_including(thinkingConfig: { includeThoughts: true }))
      )
    end

    it "preserves a user-supplied thinkingConfig (e.g. includeThoughts: false to opt out)" do
      described_class.stream!("gemini-3-flash", "hi", sink: sink, llm_api_key: google_key,
                              generation_params: { generationConfig: { thinkingConfig: { includeThoughts: false } } })
      expect(LLM::Session).to have_received(:new).with(
        llm_client, hash_including(generationConfig: hash_including(thinkingConfig: { includeThoughts: false }))
      )
    end
  end
end
