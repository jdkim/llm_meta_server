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

  describe "#strip_responses_only_params (private)" do
    it "removes :reasoning when endpoint is 'responses'" do
      out = described_class.send(:strip_responses_only_params,
                                  { reasoning: { effort: "medium" }, temperature: 0.5 },
                                  "responses")
      expect(out).to eq(temperature: 0.5)
    end

    it "matches string-keyed 'reasoning' too" do
      out = described_class.send(:strip_responses_only_params,
                                  { "reasoning" => { effort: "medium" }, "temperature" => 0.5 },
                                  "responses")
      expect(out).to eq("temperature" => 0.5)
    end

    it "is a no-op when endpoint isn't 'responses'" do
      params = { reasoning: {}, temperature: 0.5 }
      expect(described_class.send(:strip_responses_only_params, params, "chat_completions"))
        .to eq(params)
    end

    it "handles nil / empty params gracefully" do
      expect(described_class.send(:strip_responses_only_params, nil, "responses")).to be_nil
      expect(described_class.send(:strip_responses_only_params, {}, "responses")).to eq({})
    end
  end

  describe "Responses vs chat completions routing when messages: is present" do
    # gpt-5's catalog declares `endpoint: responses` and includes a `reasoning`
    # default. Multi-turn requests can't use Responses (llm.rb's adapter mislabels
    # assistant history as `input_text`), so the facade routes them through
    # chat completions and MUST strip `reasoning` so the request doesn't 400.
    let(:openai_key) {
      user = User.create!(email: "resp@example.com", google_id: "g-resp")
      user.llm_api_keys.create!(llm_type: "openai", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-oai"))
    }
    let(:openai_client) { double("LLM::OpenAI") }
    let(:responses_ns)  { double("Responses") }
    let(:session)       { instance_double("LLM::Session") }
    let(:messages_buf)  { double("MessagesBuffer") }
    let(:response)      { instance_double("Response", choices: [ instance_double("Choice", content: "ok") ], body: nil) }
    let(:sink)          { Class.new { def <<(x); self; end }.new }

    before do
      allow_any_instance_of(ApiKeyEncrypter).to receive(:encrypt).and_return("ENC")
      allow_any_instance_of(ApiKeyDecrypter).to receive(:decrypt).and_return("sk-oai")

      allow(LlmModelMap).to receive(:ollama_model?).and_return(false)
      allow(LLM).to receive(:openai).and_return(openai_client)
      allow(openai_client).to receive_message_chain(:class, :name).and_return("LLM::OpenAI")
      allow(openai_client).to receive(:server_tools).and_return({})
      allow(openai_client).to receive(:responses).and_return(responses_ns)

      allow(LLM::Session).to receive(:new).and_return(session)
      allow(session).to receive(:messages).and_return(messages_buf)
      allow(messages_buf).to receive(:concat)
      allow(session).to receive(:chat).and_return(response)
    end

    it "single-turn (messages: nil, endpoint: 'responses'): still uses the Responses API" do
      allow(responses_ns).to receive(:create).and_return(instance_double("R", output_text: "ok"))

      described_class.stream!("gpt-5", "hi", sink: sink, llm_api_key: openai_key,
                              endpoint: "responses",
                              generation_params: { reasoning: { effort: "medium" } })

      expect(responses_ns).to have_received(:create)
      # And LLM::Session isn't used at all on this branch.
      expect(LLM::Session).not_to have_received(:new)
    end

    it "multi-turn (messages: present, endpoint: 'responses'): falls back to chat completions" do
      described_class.stream!("gpt-5", "draft candidate hypothesis",
                              sink: sink, llm_api_key: openai_key,
                              endpoint: "responses",
                              generation_params: { reasoning: { effort: "medium" }, temperature: 0.4 },
                              messages: [ { role: "user", content: "prior" }, { role: "assistant", content: "prior-a" } ])

      # Chat completions path used, not Responses.
      expect(LLM::Session).to have_received(:new).with(openai_client, hash_not_including(:reasoning))
      expect(LLM::Session).to have_received(:new).with(openai_client, hash_including(temperature: 0.4))
      expect(responses_ns).not_to have_received(:create) if responses_ns.respond_to?(:create)
      # And the historical messages actually reach the session buffer.
      expect(messages_buf).to have_received(:concat) do |msgs|
        expect(msgs.length).to eq(2)
      end
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

  describe "#apply_anthropic_system! (private)" do
    # Anthropic rejects role:"system" inline in messages; we extract to the
    # top-level `system:` param. Other providers accept inline system messages,
    # so we must NOT touch them.
    let(:anthropic) { instance_double("LLM::Anthropic").tap { |d| allow(d.class).to receive(:name).and_return("LLM::Anthropic") } }
    let(:openai)    { instance_double("LLM::OpenAI").tap    { |d| allow(d.class).to receive(:name).and_return("LLM::OpenAI") } }

    def call(chat_params, messages, llm)
      described_class.send(:apply_anthropic_system!, chat_params, messages, llm)
    end

    context "with Anthropic + system message inline" do
      it "moves system content into chat_params[:system] and drops it from messages" do
        params, filtered = call({}, [
          { "role" => "system",    "content" => "be terse" },
          { "role" => "user",      "content" => "hi" },
          { "role" => "assistant", "content" => "hello" }
        ], anthropic)

        expect(params[:system]).to eq("be terse")
        expect(filtered.map { |m| m["role"] }).to eq([ "user", "assistant" ])
      end

      it "concatenates multiple system messages with a blank line" do
        params, _ = call({}, [
          { role: "system", content: "one" },
          { role: "user",   content: "hi" },
          { role: "system", content: "two" }
        ], anthropic)

        expect(params[:system]).to eq("one\n\ntwo")
      end

      it "preserves an existing chat_params[:system] and appends the extracted content" do
        # If the caller already set :system explicitly, don't clobber it.
        params, _ = call({ system: "existing persona" }, [
          { role: "system", content: "extra directive" }
        ], anthropic)

        expect(params[:system]).to eq("existing persona\n\nextra directive")
      end

      it "returns chat_params and messages unchanged when there are no system messages" do
        original_params  = { temperature: 0.5 }
        original_msgs = [ { role: "user", content: "hi" } ]

        params, filtered = call(original_params, original_msgs, anthropic)

        expect(params).to eq(original_params)
        expect(filtered).to eq(original_msgs)
      end
    end

    context "with a non-Anthropic provider (OpenAI)" do
      it "returns chat_params and messages untouched, even with role:system inline" do
        # OpenAI + Ollama accept role:"system" inline — must not extract.
        original_params  = { temperature: 0.5 }
        original_msgs = [
          { role: "system", content: "be terse" },
          { role: "user",   content: "hi" }
        ]

        params, filtered = call(original_params, original_msgs, openai)

        expect(params).to eq(original_params)
        expect(filtered).to eq(original_msgs)
      end
    end

    context "edge cases" do
      it "handles nil messages" do
        params, filtered = call({}, nil, anthropic)
        expect(params).to eq({})
        expect(filtered).to be_nil
      end

      it "handles empty messages array" do
        params, filtered = call({}, [], anthropic)
        expect(params).to eq({})
        expect(filtered).to eq([])
      end

      it "handles nil llm" do
        original_msgs = [ { role: "system", content: "x" } ]
        params, filtered = call({}, original_msgs, nil)
        expect(params).to eq({})
        expect(filtered).to eq(original_msgs)
      end

      it "skips system messages whose content is blank" do
        params, filtered = call({}, [
          { role: "system", content: "" },
          { role: "user",   content: "hi" }
        ], anthropic)

        # No system content to move — chat_params gets no :system, but the
        # empty system entry is still filtered out of the messages array.
        expect(params).not_to have_key(:system)
        expect(filtered.map { |m| m[:role] }).to eq([ "user" ])
      end
    end
  end

  describe "Anthropic system-message wiring end-to-end" do
    # These tests guard the CALL-SITE integration: apply_anthropic_system!
    # must run BEFORE LLM::Session.new at every entry point that touches
    # Anthropic, otherwise the system message would go inline in messages:
    # and Anthropic would 400. A regression here is what shipped as the
    # invalid_request_error we hit in dev.
    let(:anthropic_key) {
      user = User.create!(email: "sys@example.com", google_id: "g-sys")
      user.llm_api_keys.create!(llm_type: "anthropic", description: "personal",
                                encryptable_api_key: EncryptableApiKey.new(plain_api_key: "sk-anth"))
    }
    let(:anth_client)     { double("LLM::Anthropic") }
    let(:session)         { instance_double("LLM::Session") }
    let(:messages_buffer) { double("MessagesBuffer") }
    let(:choice)          { instance_double("Choice", content: "ok") }
    let(:response)        { instance_double("Response", choices: [ choice ], body: nil, functions: []) }
    let(:sink)            { Class.new { def <<(x); self; end }.new }

    let(:history_with_system) {
      [
        { role: "system", content: "be terse" },
        { role: "user",   content: "hello" }
      ]
    }

    before do
      allow_any_instance_of(ApiKeyEncrypter).to receive(:encrypt).and_return("ENC")
      allow_any_instance_of(ApiKeyDecrypter).to receive(:decrypt).and_return("sk-anth")

      allow(LlmModelMap).to receive(:ollama_model?).and_return(false)
      allow(LLM).to receive(:anthropic).and_return(anth_client)
      allow(anth_client).to receive_message_chain(:class, :name).and_return("LLM::Anthropic")
      allow(anth_client).to receive(:server_tools).and_return({})

      allow(LLM::Session).to receive(:new).and_return(session)
      allow(session).to receive(:messages).and_return(messages_buffer)
      allow(messages_buffer).to receive(:concat)
      allow(session).to receive(:chat).and_return(response)
      allow(session).to receive(:functions).and_return([])
      allow(session).to receive(:extract_tool_calls).and_return([])
    end

    it "stream! (plain path): threads system: into LLM::Session.new and strips it from seeded messages" do
      described_class.stream!("claude-opus-4-8", "hi",
                              sink: sink, llm_api_key: anthropic_key,
                              messages: history_with_system)

      # 1. The system content reached LLM::Session.new as a top-level kwarg
      expect(LLM::Session).to have_received(:new).with(
        anth_client, hash_including(system: "be terse")
      )
      # 2. And the seeded history no longer contains role:system —
      #    only the user turn survives (assistant history unchanged).
      expect(messages_buffer).to have_received(:concat) do |msgs|
        expect(msgs.map(&:role).map(&:to_s)).to eq([ "user" ])
      end
    end

    it "stream_chat_with_tools! (tools path — the one that failed in dev): threads system: through" do
      tool = double("tool")
      # Provide a full tools-loop stub so the branch actually runs.
      allow(session).to receive(:chat).with("hi", stream: false).and_return(response)
      allow(session).to receive(:functions).and_return([])

      described_class.stream!("claude-opus-4-8", "hi",
                              sink: sink, llm_api_key: anthropic_key,
                              tools: [ tool ], messages: history_with_system)

      expect(LLM::Session).to have_received(:new).with(
        anth_client, hash_including(system: "be terse", tools: [ tool ])
      )
      expect(messages_buffer).to have_received(:concat) do |msgs|
        expect(msgs.map(&:role).map(&:to_s)).to eq([ "user" ])
      end
    end

    it "call! (non-streaming path): threads system: through execute_chat!" do
      described_class.call!("claude-opus-4-8", "hi",
                            llm_api_key: anthropic_key,
                            messages: history_with_system)

      expect(LLM::Session).to have_received(:new).with(
        anth_client, hash_including(system: "be terse")
      )
      expect(messages_buffer).to have_received(:concat) do |msgs|
        expect(msgs.map(&:role).map(&:to_s)).to eq([ "user" ])
      end
    end

    it "does NOT set system: when messages contain no role:system entry (backward compat)" do
      described_class.stream!("claude-opus-4-8", "hi",
                              sink: sink, llm_api_key: anthropic_key,
                              messages: [ { role: "user", content: "hi again" } ])

      expect(LLM::Session).to have_received(:new).with(
        anth_client, hash_not_including(:system)
      )
    end
  end
end
