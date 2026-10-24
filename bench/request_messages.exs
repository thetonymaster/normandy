# AgentMemory.request_messages_for/2, which builds every LLM request's messages from the
# whole history (it runs on every call). Settles how request building scales with
# history length.
Code.require_file("support.exs", __DIR__)

alias Bench.Support
alias Normandy.Agents.BaseAgentOutputSchema
alias Normandy.Agents.ToolCallResponse
alias Normandy.Components.AgentMemory
alias Normandy.Components.ToolCall
alias Normandy.Components.ToolResult

# The request's prefix key differs from the one the responses were stamped with, so
# their thinking is stale and the drop path runs too.
prefix_key = 0

question = "What is the weather like in Paris today, and should I bring an umbrella?"
answer = %BaseAgentOutputSchema{chat_message: "Mild and dry; no umbrella needed today."}

tool_round = fn i ->
  call = %ToolCall{id: "call_#{i}", name: "lookup", input: %{"q" => "paris weather"}}

  thinking = %{
    "type" => "thinking",
    "thinking" => "I should look it up.",
    "signature" => "sig#{i}"
  }

  response = %ToolCallResponse{
    content: nil,
    tool_calls: [call],
    thinking: [thinking],
    content_blocks: [
      thinking,
      %{"type" => "tool_use", "id" => call.id, "name" => "lookup", "input" => call.input}
    ],
    prefix_key: 1
  }

  [
    {"assistant", response},
    {"tool", %ToolResult{tool_call_id: call.id, output: %{"temp_c" => 18, "rain" => false}}}
  ]
end

# `n` stored messages: user/assistant turns; in the rich variant every fifth turn
# answers through a tool round (assistant tool_use with thinking, tool result).
memory = fn n, rich? ->
  0
  |> Stream.iterate(&(&1 + 1))
  |> Stream.flat_map(fn turn ->
    round = if rich? and rem(turn, 5) == 4, do: tool_round.(turn), else: []
    [{"user", question}] ++ round ++ [{"assistant", answer}]
  end)
  |> Enum.take(n)
  |> Enum.reduce(AgentMemory.new_memory(), fn {role, content}, m ->
    AgentMemory.add_message(m, role, content)
  end)
end

sizes = [{"10 msgs", 10}, {"100 msgs", 100}, {"1k msgs", 1_000}, {"5k msgs", 5_000}]

inputs =
  Map.new(sizes, fn {name, n} -> {name, %{plain: memory.(n, false), rich: memory.(n, true)}} end)

plain = AgentMemory.request_messages_for(inputs["100 msgs"].plain, prefix_key)
Support.assert!(length(plain) == 100, "100 plain messages must give 100 request messages")

rich = AgentMemory.request_messages_for(inputs["100 msgs"].rich, prefix_key)

Support.assert!(
  rich != [] and Enum.all?(rich, &match?(%{role: _, content: _}, &1)),
  "the rich memory must give request messages"
)

Support.banner(
  "AgentMemory.request_messages_for/2",
  Enum.map(sizes, &elem(&1, 0)),
  "linear in message count (runs on every LLM call)"
)

Benchee.run(
  %{
    "plain" => fn input -> AgentMemory.request_messages_for(input.plain, prefix_key) end,
    "tool rounds + thinking" => fn input ->
      AgentMemory.request_messages_for(input.rich, prefix_key)
    end
  },
  Support.run_opts("request_messages", inputs: inputs)
)
