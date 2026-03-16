require 'rails_helper'

RSpec.describe LlmRbFacade do
  let(:llm_client) { instance_double("LLM::Provider") }
  let(:session) { instance_double("LLM::Session") }
  let(:messages) { instance_double("Messages", choices: [ choice ]) }
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
end
