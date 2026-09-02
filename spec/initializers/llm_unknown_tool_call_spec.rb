require "rails_helper"

# Regression guard for the "undefined method 'id=' for nil" crash.
#
# Stock llm.rb (message.rb:72-76) assumes every tool call the model emits
# names a tool that was on the request. When it doesn't, `find` returns nil,
# `nil.dup` stays nil, and `nil.id =` raises — killing the whole stream. Seen
# in production with qwen3.6:35b over 29 TogoMCP tools: the model invented a
# name on a follow-up turn and the user got an opaque error instead of an
# answer. See config/initializers/llm_unknown_tool_call.rb.
RSpec.describe LLM::Message, "#functions with an unknown tool name" do
  def tool(name)
    LLM::Function.new(name) { |f| f.define ->(**) { { "called" => name } } }
  end

  def message_with(tool_calls, tools)
    LLM::Message.new(
      "assistant", "",
      tool_calls: tool_calls,
      response: double("LLM::Response", __tools__: tools)
    )
  end

  let(:tools) { [ tool("run_sparql"), tool("get_MIE_file") ] }

  context "when the model names a tool that was never offered" do
    let(:message) do
      message_with([ { "id" => "call_1", "name" => "find_databases", "arguments" => { "q" => "x" } } ], tools)
    end

    it "does not raise" do
      expect { message.functions }.not_to raise_error
    end

    it "still yields one function per tool call" do
      expect(message.functions.size).to eq(1)
      expect(message.functions.first.name).to eq("find_databases")
    end

    it "carries the tool call id through so the result pairs with the call" do
      expect(message.functions.first.id).to eq("call_1")
    end

    it "is pending, so Session#functions picks it up and the loop executes it" do
      expect(message.functions.first).to be_pending
    end

    it "returns an MCP-shaped isError payload that emit_tool_errors_to_sink understands" do
      value = message.functions.first.call.value

      expect(value).to be_a(Hash)
      expect(value["isError"]).to be true
      expect(value.dig("content", 0, "text")).to include('"find_databases"')
    end

    it "tells the model which tools it may actually call" do
      text = message.functions.first.call.value.dig("content", 0, "text")

      expect(text).to include("get_MIE_file")
      expect(text).to include("run_sparql")
    end
  end

  describe "argument shapes that would splat badly" do
    # LLM::Function#call does `runner.call(**arguments)`, so a hallucinated
    # call carrying nil or a non-Hash must not blow up a second time.
    [ nil, "not-a-hash", [ 1, 2 ] ].each do |args|
      it "survives arguments of #{args.inspect}" do
        message = message_with([ { "id" => "c", "name" => "nope", "arguments" => args } ], tools)

        expect { message.functions.first.call }.not_to raise_error
      end
    end
  end

  context "when no tools were offered at all" do
    it "stubs every call rather than raising" do
      message = message_with([ { "id" => "c1", "name" => "anything" } ], [])

      expect { message.functions }.not_to raise_error
      expect(message.functions.first.call.value["isError"]).to be true
    end
  end

  context "when the tool name is known" do
    let(:message) do
      message_with([ { "id" => "call_9", "name" => "run_sparql", "arguments" => { "query" => "SELECT 1" } } ], tools)
    end

    it "resolves to the real tool and runs it" do
      fn = message.functions.first

      expect(fn.name).to eq("run_sparql")
      expect(fn.call.value).to eq({ "called" => "run_sparql" })
    end

    it "sets id and arguments from the tool call" do
      fn = message.functions.first

      expect(fn.id).to eq("call_9")
      expect(fn.arguments.to_h).to eq({ "query" => "SELECT 1" })
    end

    it "works on a dup so the shared tool definition is not mutated" do
      message.functions

      expect(tools.first.id).to be_nil
      expect(tools.first.arguments).to be_nil
    end
  end

  context "with a mix of known and unknown names" do
    let(:message) do
      message_with([
        { "id" => "a", "name" => "run_sparql",     "arguments" => {} },
        { "id" => "b", "name" => "totally_made_up", "arguments" => {} },
        { "id" => "c", "name" => "get_MIE_file",   "arguments" => {} }
      ], tools)
    end

    it "keeps every call, in order, so results still line up with the calls" do
      expect(message.functions.map(&:name)).to eq(%w[run_sparql totally_made_up get_MIE_file])
      expect(message.functions.map(&:id)).to eq(%w[a b c])
    end

    it "only the unknown one errors; the real ones still execute" do
      values = message.functions.map { |f| f.call.value }

      expect(values[0]).to eq({ "called" => "run_sparql" })
      expect(values[1]["isError"]).to be true
      expect(values[2]).to eq({ "called" => "get_MIE_file" })
    end
  end
end
