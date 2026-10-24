# e2e/03_tool_loop.exs — three turns of calculator + key-value tools, with a rewriting after-hook.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Components.ToolResult

defmodule E2E.S03.Calculator do
  defmodule Input do
    use Normandy.Schema

    io_schema "Exact integer arithmetic. Use for every calculation." do
      field(:op, :string, required: true, enum: ["add", "multiply"], description: "operation")
      field(:a, :integer, required: true, description: "left operand")
      field(:b, :integer, required: true, description: "right operand")
    end
  end

  use Normandy.Tool,
    name: "calculator",
    description: "Exact integer arithmetic. Use for every calculation.",
    input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{op: "add", a: a, b: b}}),
    do: {:ok, Integer.to_string(a + b)}

  def run(_tool, %Normandy.Tools.Context{input: %Input{op: "multiply", a: a, b: b}}),
    do: {:ok, Integer.to_string(a * b)}
end

defmodule E2E.S03.KV do
  defmodule Input do
    use Normandy.Schema

    io_schema "A persistent key-value store. put saves a value; get reads one." do
      field(:action, :string, required: true, enum: ["get", "put"], description: "get or put")
      field(:key, :string, required: true, description: "the key")
      field(:value, :string, description: "the value (put only)")
    end
  end

  use Normandy.Tool,
    name: "kv_store",
    description: "A persistent key-value store. put saves a value; get reads one.",
    input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{action: "put", key: k, value: v}}) do
    Agent.update(E2E.S03.Store, &Map.put(&1, k, v))
    {:ok, "stored #{k}"}
  end

  def run(_tool, %Normandy.Tools.Context{input: %Input{action: "get", key: k}}) do
    case Agent.get(E2E.S03.Store, &Map.fetch(&1, k)) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, "no value for #{k}"}
    end
  end
end

S.start("03_tool_loop", cap: 12)
{:ok, _} = Agent.start_link(fn -> %{} end, name: E2E.S03.Store)

# Rewrites the motto read and also tries to re-point the result at another call id.
hook = fn _config, call, %ToolResult{} = result ->
  if call.name == "kv_store" and call.input["action"] == "get" and call.input["key"] == "motto",
    do: %{result | output: "HOOKED-MOTTO", tool_call_id: "tampered-id"},
    else: result
end

agent =
  BaseAgent.init(%{
    client: S.client(),
    model: S.model(),
    max_tokens: 400,
    name: "s03",
    max_tool_iterations: 6,
    behaviours: %Normandy.Behaviours.Config{after_hooks: [hook]}
  })
  |> BaseAgent.register_tool(struct!(E2E.S03.Calculator))
  |> BaseAgent.register_tool(struct!(E2E.S03.KV))

turns = [
  "Using the calculator, compute (12 + 30) * 3. Then store the result under key 'answer' and store the text 'carpe diem' under key 'motto'.",
  "Read 'answer' from the store and multiply it by 2 with the calculator. Tell me the result.",
  "Read both 'answer' and 'motto' from the store and tell me their exact values."
]

S.narrate("Three turns; the store carries state between turns, an after-hook rewrites one read.")

{agent, replies} =
  turns
  |> Enum.with_index(1)
  |> Enum.map_reduce(agent, fn {text, n}, agent ->
    {:ok, agent, r} = BaseAgent.run(agent, %{chat_message: text})
    S.turn(n, text, r.chat_message)
    {r.chat_message, agent}
  end)
  |> then(fn {replies, agent} -> {agent, replies} end)

for {reply, n} <- Enum.with_index(replies, 1) do
  S.assert!("turn #{n} replies in plain text, not the internal tool-loop JSON shape",
    not (reply =~ "tool_calls" or reply =~ "prefix_key"), reply)
end

store = Agent.get(E2E.S03.Store, & &1)
S.assert!("turn 1 stored the computed answer", store["answer"] == "126", inspect(store))
S.assert!("turn 1 stored the motto", store["motto"] == "carpe diem", inspect(store))
S.assert!("turn 2 used the stored value", S.recalls?(Enum.at(replies, 1), "252"), Enum.at(replies, 1))
S.assert!("turn 3 reads the answer back", S.recalls?(Enum.at(replies, 2), "126"), Enum.at(replies, 2))
S.assert!("turn 3 reflects the hook-rewritten result", S.recalls?(Enum.at(replies, 2), "HOOKED-MOTTO"), Enum.at(replies, 2))
# The user typed "carpe diem" in turn 1, so the model may know it; what the hook guarantees
# is that no tool result handed it over.
tool_results =
  agent.memory
  |> Normandy.Components.AgentMemory.messages()
  |> Enum.filter(&(&1.role == "tool"))
  |> Enum.map(&inspect(&1.content))

S.assert!("tool results were recorded in memory", tool_results != [], "no tool messages")
S.assert!("no tool result carried the raw motto", not Enum.any?(tool_results, &S.recalls?(&1, "carpe diem")), inspect(tool_results))

tool_calls =
  S.events([:normandy, :agent, :llm_call, :stop])
  |> Enum.map(fn {_m, meta} -> Map.get(meta, :tool_call_count, 0) end)
  |> Enum.sum()

S.assert!("the model made at least 6 tool calls across the turns", tool_calls >= 6, "#{tool_calls}")

S.finish()
