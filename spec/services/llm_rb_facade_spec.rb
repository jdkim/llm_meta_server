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
