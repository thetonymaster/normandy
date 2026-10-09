# e2e/15_preserved_thinking.exs — AX-7: Normandy's history replays under preserved thinking.
# Opus 5.5 with thinking_block_binding: :error rejects a request whose replayed thinking no
# longer matches the conversation it was produced in. A tool loop that reaches its iteration
# cap (the final call: tool_choice :none and the notice, output_config.format beside the
# tools), then run/3 and stream/3 on the same memory, must all be accepted.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.{BaseAgent, ToolCallResponse}
alias Normandy.Components.{AgentMemory, Message}

defmodule E2E.S15.Stock do
  use Normandy.Schema

  io_schema "Stock levels the agent looked up" do
    field(:total, :integer, required: true, description: "sum of the units of every SKU looked up")
    field(:skus, {:array, :string}, required: true, description: "the SKUs looked up, in order")
  end
end

defmodule E2E.S15.Lookup do
  defmodule Input do
    use Normandy.Schema

    io_schema "Look up one SKU's stock." do
      field(:sku, :string, required: true, description: "the SKU, for example A1")
    end
  end

  use Normandy.Tool,
    name: "stock_lookup",
    description: "Look up one SKU's stock. The result may name a linked SKU to look up next.",
    input: Input

  defstruct []

  @stock %{
    "A1" => "7 units. Linked SKU: B2 (look it up too).",
    "B2" => "5 units. No linked SKU.",
    "C3" => "4 units. No linked SKU."
  }

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{sku: sku}}) do
    case Map.fetch(@stock, String.upcase(sku)) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, "unknown SKU #{sku}; known: A1, B2, C3"}
    end
  end
end

S.start("15_preserved_thinking", cap: 8)

agent =
  BaseAgent.init(%{
    client: S.client(%{thinking: :adaptive, thinking_block_binding: :error, recv_timeout: 180_000}),
    model: S.model(:opus),
    max_tokens: 4_000,
    name: "s15",
    output_schema: struct!(E2E.S15.Stock),
    max_tool_iterations: 2
  })
  |> BaseAgent.register_tool(struct!(E2E.S15.Lookup))

# An LLMError's message carries the API's text: a 400 naming thinking is the finding.
expect_stock = fn label, result ->
  case result do
    {:ok, agent, %E2E.S15.Stock{} = stock} -> {agent, stock}
    {:error, error} -> S.assert!(label, false, Exception.message(error))
    other -> S.assert!(label, false, inspect(other))
  end
end

thinking_replayed? = fn agent ->
  agent.memory
  |> AgentMemory.messages()
  |> Enum.any?(fn
    %Message{role: "assistant", content: %ToolCallResponse{content_blocks: blocks}} ->
      Enum.any?(blocks, &(&1["type"] in ["thinking", "redacted_thinking"]))

    _other ->
      false
  end)
end

S.narrate("Run 1: two chained lookups, then the iteration cap forces the final call.")
before = S.calls()

{agent, s1} =
  expect_stock.(
    "run 1 is accepted",
    BaseAgent.run(agent, %{
      chat_message:
        "Look up SKU A1 with stock_lookup. Its result names a linked SKU: look that one up " <>
          "too, one call at a time. Then report the total units and the SKUs."
    })
  )

S.turn(1, "A1 and its linked SKU", inspect(s1))
S.assert!("run 1 made 3 calls: two tool rounds, then the forced final call", S.calls() - before == 3, "#{S.calls() - before}")
S.assert!("run 1 totals A1 + B2 = 12", s1.total == 12, inspect(s1))
S.assert!("memory holds thinking blocks to replay (else this probe proves nothing)", thinking_replayed?.(agent), "no thinking block in any assistant tool turn")

S.narrate("Run 2 (run/3) on the same memory: run 1's thinking, tool and notice blocks replay.")

{agent, s2} =
  expect_stock.(
    "run 2 is accepted (replayed thinking still binds)",
    BaseAgent.run(agent, %{chat_message: "Also look up SKU C3 and report the new total of all three SKUs."})
  )

S.turn(2, "add C3", inspect(s2))
S.assert!("run 2 totals 16", s2.total == 16, inspect(s2))

S.narrate("Run 3 (stream/3) on the same memory.")

{_agent, s3} =
  expect_stock.(
    "the streamed run 3 is accepted",
    BaseAgent.stream(agent, %{chat_message: "Repeat the total and the SKUs. No lookups."}, fn _event -> :ok end)
  )

S.turn(3, "repeat", inspect(s3))
S.assert!("run 3 repeats 16", s3.total == 16, inspect(s3))

S.finish()
