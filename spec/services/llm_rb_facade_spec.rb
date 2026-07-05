require 'rails_helper'

RSpec.describe LlmRbFacade do
  let(:llm_client) { instance_double("LLM::Provider") }
  let(:session) { instance_double("LLM::Session") }
  let(:messages) { instance_double("Messages", choices: [ choice ], body: nil) }
  let(:choice) { instance_double("Choice", content: "Hello!") }
  let(:model_id) { "llama3.2" }
  let(:prompt) { "Hi there" }

  before do
    allow(LlmModelMap).to receive(:ollama_model?).with(model_id).and_return(true)
    allow(LLM).to receive(:ollama).and_return(llm_client)
  end

  describe ".call!" do
    context "without generation_params" do
      it "creates a session without extra params" do
        allow(LLM::Session).to receive(:new).with(llm_client, model: model_id).and_return(session)
        allow(session).to receive(:chat).with(prompt).and_return(messages)

        result = described_class.call!(model_id, prompt)
        expect(result).to eq("Hello!")
      end
    end

    context "with generation_params" do
      let(:generation_params) { { temperature: 0.7, max_tokens: 1024 } }

      it "passes generation_params to Session.new" do
        allow(LLM::Session).to receive(:new)
          .with(llm_client, model: model_id, temperature: 0.7, max_tokens: 1024)
          .and_return(session)
        allow(session).to receive(:chat).with(prompt).and_return(messages)

        result = described_class.call!(model_id, prompt, generation_params: generation_params)
        expect(result).to eq("Hello!")
      end
    end

    context "with tools and generation_params" do
      let(:tools) { [ double("tool") ] }
      let(:generation_params) { { temperature: 0.5 } }
      let(:functions) { [] }

      it "passes generation_params to Session.new alongside tools" do
        allow(LLM::Session).to receive(:new)
          .with(llm_client, model: model_id, tools: tools, temperature: 0.5)
          .and_return(session)
        allow(session).to receive(:chat).with(prompt).and_return(messages)
        allow(session).to receive(:functions).and_return(functions)
        allow(session).to receive(:extract_tool_calls).and_return([])

        result = described_class.call!(model_id, prompt, tools: tools, generation_params: generation_params)
        expect(result).to eq("Hello!")
      end
    end
  end

  describe "#coerce_file_payloads (private)" do
    subject(:facade) { described_class }

    it "returns just images when no document" do
      out = facade.send(:coerce_file_payloads, nil, [ { mime: "image/png", data_b64: "A" } ], nil)
      expect(out).to eq([ { mime: "image/png", data_b64: "A" } ])
    end

    it "appends the document after images so it lands last in the payloads" do
      img = { mime: "image/png", data_b64: "A" }
      doc = { mime: "application/pdf", data_b64: "B" }
      out = facade.send(:coerce_file_payloads, nil, [ img ], doc)
      expect(out).to eq([ img, doc ])
    end

    it "returns just the document when no images at all" do
      doc = { mime: "application/pdf", data_b64: "P" }
      out = facade.send(:coerce_file_payloads, nil, nil, doc)
      expect(out).to eq([ doc ])
    end

    it "returns [] when everything is blank" do
      expect(facade.send(:coerce_file_payloads, nil, nil, nil)).to eq([])
      expect(facade.send(:coerce_file_payloads, nil, [], nil)).to eq([])
    end

    it "still handles the legacy single `image:` kwarg" do
      img = { mime: "image/png", data_b64: "A" }
      expect(facade.send(:coerce_file_payloads, img, nil, nil)).to eq([ img ])
    end
  end

  describe "#native_server_tools (private)" do
    let(:google_search_tool) { double("google_search") }
    let(:url_context_tool)   { double("url_context") }
    let(:anth_web_search)    { double("anth_web_search") }

    it "returns google_search + url_context for a Gemini provider" do
      llm = double("LLM::Gemini")
      allow(llm).to receive(:server_tools).and_return(
        google_search: google_search_tool, url_context: url_context_tool
      )
      allow(llm.class).to receive(:name).and_return("LLM::Gemini")

      out = described_class.send(:native_server_tools, llm)
      expect(out).to contain_exactly(google_search_tool, url_context_tool)
    end

    it "returns web_search for an Anthropic provider" do
      llm = double("LLM::Anthropic")
      allow(llm).to receive(:server_tools).and_return(web_search: anth_web_search)
      allow(llm.class).to receive(:name).and_return("LLM::Anthropic")

      out = described_class.send(:native_server_tools, llm)
      expect(out).to eq([ anth_web_search ])
    end

    it "returns [] for an OpenAI provider (Responses-only tools not routed yet)" do
      llm = double("LLM::OpenAI")
      allow(llm).to receive(:server_tools).and_return(web_search: double("oai_web"))
      allow(llm.class).to receive(:name).and_return("LLM::OpenAI")

      expect(described_class.send(:native_server_tools, llm)).to eq([])
    end

    it "returns [] for Ollama" do
      llm = double("LLM::Ollama")
      allow(llm).to receive(:server_tools).and_return({})
      allow(llm.class).to receive(:name).and_return("LLM::Ollama")

      expect(described_class.send(:native_server_tools, llm)).to eq([])
    end

    it "returns [] when the provider doesn't expose server_tools at all" do
      llm = double("LLM::Something")
      allow(llm).to receive(:respond_to?).with(:server_tools).and_return(false)
      expect(described_class.send(:native_server_tools, llm)).to eq([])
    end

    it "swallows unexpected errors and returns [] (fail-open on tool registry)" do
      llm = double("LLM::Gemini")
      allow(llm).to receive(:server_tools).and_raise(ArgumentError, "boom")
      allow(llm.class).to receive(:name).and_return("LLM::Gemini")

      expect(described_class.send(:native_server_tools, llm)).to eq([])
    end
  end

  describe "#messages_to_llm_objects (private) — history array → LLM::Message list" do
    it "converts symbol-keyed and string-keyed entries uniformly" do
      out = described_class.send(:messages_to_llm_objects, [
        { role: "user", content: "u1" },
        { "role" => "assistant", "content" => "a1" }
      ])
      expect(out.length).to eq(2)
      expect(out.map(&:role).map(&:to_s)).to eq([ "user", "assistant" ])
      expect(out.map(&:content)).to eq([ "u1", "a1" ])
    end

    it "drops entries with blank content or missing role" do
      out = described_class.send(:messages_to_llm_objects, [
        { role: "user", content: "" },
        { role: "",     content: "x" },
        { role: "user", content: "keep me" }
      ])
      expect(out.length).to eq(1)
      expect(out.first.content).to eq("keep me")
    end

    it "returns [] for nil / empty input" do
      expect(described_class.send(:messages_to_llm_objects, nil)).to eq([])
      expect(described_class.send(:messages_to_llm_objects, [])).to eq([])
    end
  end

  describe "messages: kwarg — pre-seeds LLM::Session history before the current turn" do
    let(:anthropic_key) {
      user = User.create!(email: "seed@example.com", google_id: "g-seed")
      user.llm_api_keys.create!(llm_type: "anthropic", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-anth"))
    }
    let(:anth_client)     { double("LLM::Anthropic") }
    let(:session)         { instance_double("LLM::Session") }
    let(:messages_buffer) { double("MessagesBuffer") }
    let(:response)        { instance_double("Response", choices: [ instance_double("Choice", content: "ok") ], body: nil) }
    let(:sink)            { Class.new { def <<(x); self; end }.new }

    let(:history) {
      [
        { role: "user",      content: "Extract the appraised evidence as JSON" },
        { role: "assistant", content: "{\"appraised_evidence\": []}" }
      ]
    }

    before do
      allow_any_instance_of(ApiKeyEncrypter).to receive(:encrypt).and_return("ENC")
      allow_any_instance_of(ApiKeyDecrypter).to receive(:decrypt).and_return("sk-anth")

      allow(LlmModelMap).to receive(:ollama_model?).and_return(false)
      allow(LLM).to receive(:anthropic).and_return(anth_client)
      allow(anth_client).to receive_message_chain(:class, :name).and_return("LLM::Anthropic")
      # Anthropic's native web_search auto-attaches — surface an empty tool
      # registry for this test so the request lands in the vanilla branch.
      allow(anth_client).to receive(:server_tools).and_return({})

      allow(LLM::Session).to receive(:new).and_return(session)
      allow(session).to receive(:messages).and_return(messages_buffer)
      allow(messages_buffer).to receive(:concat)
      allow(session).to receive(:chat).and_return(response)
    end

    it "stream!: concatenates history LLM::Message objects into session.messages before .chat" do
      described_class.stream!("claude-sonnet-4-6", "draft candidate hypothesis",
                              sink: sink, llm_api_key: anthropic_key, messages: history)

      expect(messages_buffer).to have_received(:concat) do |msgs|
        expect(msgs.length).to eq(2)
        expect(msgs.map(&:role).map(&:to_s)).to eq([ "user", "assistant" ])
        expect(msgs[0].content).to eq("Extract the appraised evidence as JSON")
        expect(msgs[1].content).to eq("{\"appraised_evidence\": []}")
      end
      # And the current user turn is passed to .chat as the CURRENT prompt.
      expect(session).to have_received(:chat).with("draft candidate hypothesis", stream: sink)
    end

    it "stream!: skips the seed step when messages is nil (backward compat)" do
      described_class.stream!("claude-sonnet-4-6", "hi",
                              sink: sink, llm_api_key: anthropic_key, messages: nil)
      expect(messages_buffer).not_to have_received(:concat)
    end

    it "call!: also pre-seeds the session before the .chat call" do
      described_class.call!("claude-sonnet-4-6", "draft candidate hypothesis",
                            llm_api_key: anthropic_key, messages: history)

      expect(messages_buffer).to have_received(:concat) do |msgs|
        expect(msgs.map(&:content)).to eq([ history[0][:content], history[1][:content] ])
      end
    end
  end

  describe "native-tool wiring through stream! / call! (Anthropic)" do
    # Verify that native_server_tools' output actually reaches the downstream
    # LLM::Session. Guards against silent regressions in the branching logic
    # (native-only, tool-loop merge, and non-streaming call!).
    let(:anthropic_key) {
      user = User.create!(email: "nt@example.com", google_id: "g-native")
      user.llm_api_keys.create!(llm_type: "anthropic", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-anth"))
    }
    # Plain double (not instance_double) because LLM::Provider is an abstract
    # base and the surface methods live on the subclass — instance_double
    # rejects respond_to? stubs against methods it can't verify.
    let(:anth_client)   { double("LLM::Anthropic") }
    let(:web_search)    { double("anthropic_web_search") }
    let(:sink)          { Class.new { def <<(x); self; end }.new }
    let(:session)       { instance_double("LLM::Session") }
    let(:choice)        { instance_double("Choice", content: "ok") }
    let(:response)      { instance_double("Response", choices: [ choice ], body: nil) }
    let(:model)         { "claude-sonnet-4-6" }

    before do
      allow_any_instance_of(ApiKeyEncrypter).to receive(:encrypt).and_return("ENC")
      allow_any_instance_of(ApiKeyDecrypter).to receive(:decrypt).and_return("sk-anth")

      allow(LlmModelMap).to receive(:ollama_model?).and_return(false)
      allow(LLM).to receive(:anthropic).and_return(anth_client)
      # Plain double replies true to `respond_to?` for stubbed methods, which
      # is exactly what native_server_tools needs.
      allow(anth_client).to receive_message_chain(:class, :name).and_return("LLM::Anthropic")
      allow(anth_client).to receive(:server_tools).and_return(web_search: web_search)

      allow(LLM::Session).to receive(:new).and_return(session)
      allow(session).to receive(:chat).and_return(response)
    end

    it "stream! (native-only branch): passes web_search into LLM::Session.new tools" do
      described_class.stream!(model, "search that", sink: sink, llm_api_key: anthropic_key)

      expect(LLM::Session).to have_received(:new).with(
        anth_client, hash_including(tools: [ web_search ])
      )
    end

    it "stream! (native + MCP tools): merges web_search alongside MCP function tools in the tool loop" do
      mcp_tool = double("mcp_function_tool")
      allow(session).to receive(:functions).and_return([])
      allow(session).to receive(:extract_tool_calls).and_return([])

      described_class.stream!(model, "search that", sink: sink, llm_api_key: anthropic_key,
                              tools: [ mcp_tool ])

      # The tool-loop branch calls Session.new with the merged list (MCP + native).
      expect(LLM::Session).to have_received(:new).with(
        anth_client, hash_including(tools: contain_exactly(mcp_tool, web_search))
      )
    end

    it "call! (non-streaming): passes web_search into LLM::Session.new tools" do
      allow(session).to receive(:functions).and_return([])
      allow(session).to receive(:extract_tool_calls).and_return([])

      described_class.call!(model, "search that", llm_api_key: anthropic_key)

      expect(LLM::Session).to have_received(:new).with(
        anth_client, hash_including(tools: [ web_search ])
      )
    end
  end

  describe "#with_file_payloads (private) — MIME → Tempfile extension" do
    it "writes a PDF payload to a .pdf-suffixed Tempfile so LLM::File detects PDF-ness" do
      payload = { mime: "application/pdf", data_b64: Base64.strict_encode64("%PDF-1.4") }
      captured_path = nil
      described_class.send(:with_file_payloads, [ payload ]) do |contents|
        captured_path = contents.first.value.path
      end
      expect(captured_path).to end_with(".pdf")
    end

    it "writes an image payload to an image-extension Tempfile" do
      payload = { mime: "image/png", data_b64: Base64.strict_encode64("PNGdata") }
      captured_path = nil
      described_class.send(:with_file_payloads, [ payload ]) do |contents|
        captured_path = contents.first.value.path
      end
      expect(captured_path).to end_with(".png")
    end

    it "yields [] and cleans up when payloads is empty" do
      yielded = :sentinel
      described_class.send(:with_file_payloads, []) { |c| yielded = c }
      expect(yielded).to eq([])
    end
  end
end
