require "rails_helper"

# Regression test for tool calls in a STREAMED tool round.
#
# llm.rb's Ollama StreamParser accumulated only `content` across chunks, so a
# `tool_calls` entry arriving in any chunk after the first was silently
# dropped. LlmRbFacade runs turn 1 non-streamed but streams every round after
# it, and models normally write a sentence before acting — so a streamed
# conversation made exactly one tool call (turn 1) and never another. The model
# kept announcing a next step it never took, and nothing errored.
#
# spec/initializers/ollama_stream_parser_spec.rb pins `merge!` directly. This
# spec drives the whole path over stubbed HTTP instead, so the *behaviour*
# stays protected even if the monkey-patch, the gem internals, or the facade's
# streaming strategy change. Without that, the unit specs would keep passing
# while the feature broke — which is how the original bug survived.
RSpec.describe LlmRbFacade, "streamed tool rounds" do
  let(:user)   { User.create!(email: "mcp-stream@example.com", google_id: "g-mcp-stream") }
  let(:server) { McpServer.create!(user: user, name: "T", url: "https://mcp.example.com/mcp") }
  let(:mcp_tool) do
    server.mcp_tools.create!(
      name: "lookup", description: "Look something up",
      input_schema: { "type" => "object", "properties" => { "q" => { "type" => "string" } } }
    )
  end

  let(:sink) do
    Class.new do
      def initialize = @buf = +""
      def <<(chunk)
        @buf << chunk.to_s
        self
      end
      def thinking(_delta) = nil
      def buf = @buf
    end.new
  end

  # Ollama streams NDJSON: one JSON object per line.
  def ndjson(*objs) = objs.map(&:to_json).join("\n") + "\n"

  def msg(content: "", tool_calls: nil, done: false)
    m = { "role" => "assistant", "content" => content }
    m["tool_calls"] = tool_calls if tool_calls
    { "message" => m, "done" => done }
  end

  def tool_call(name, args) = { "function" => { "name" => name, "arguments" => args } }

  before do
    allow(LlmModelMap).to receive(:ollama_model?).and_return(true)
    # The MCP transport has its own spec; keep this one on the provider path.
    client = instance_double(McpClient)
    allow(McpClient).to receive(:new).and_return(client)
    allow(client).to receive(:initialize_connection!)
    allow(client).to receive(:call_tool!)
      .and_return({ "content" => [ { "type" => "text", "text" => "a result" } ] })
  end

  it "executes a tool call that arrives after text in a streamed round" do
    stub_request(:post, %r{/api/chat}).to_return(
      # Turn 1 — non-streamed, a single complete JSON object.
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: msg(tool_calls: [ tool_call("lookup", { "q" => "first" }) ], done: true).to_json },
      # Round 2 — streamed, text FIRST and the tool_call in a later chunk.
      # This is precisely the shape that used to be discarded.
      { status: 200, headers: { "Content-Type" => "application/x-ndjson" },
        body: ndjson(msg(content: "Let me check that. "),
                     msg(tool_calls: [ tool_call("lookup", { "q" => "second" }) ]),
                     msg(done: true)) },
      # Round 3 — streamed, final answer with no further calls, so the loop ends.
      { status: 200, headers: { "Content-Type" => "application/x-ndjson" },
        body: ndjson(msg(content: "Done: "), msg(content: "two lookups", done: true)) }
    )

    rounds = []
    LlmRbFacade.stream!("qwen3.8:27b", "go", sink: sink,
                        tools: McpToolAdapter.to_llm_functions([ mcp_tool ]),
                        generation_params: { options: { num_ctx: 8192 } },
                        on_tool_calls: ->(zipped) { rounds << Array(zipped).size })

    # Two rounds: turn 1's call, then the streamed round's call. Before the fix
    # the second vanished and the loop exited after one round.
    expect(rounds.size).to eq(2)
    expect(sink.buf).to include("two lookups")
  end
end
