# e2e/13_budget_policy.exs — a denied destructive tool, then a tool budget that runs out mid-conversation.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Behaviours.{Config, PolicyEngine}
alias Normandy.Components.AgentMemory

defmodule E2E.S13.Budget do
  @behaviour Normandy.Behaviours.BudgetTracker

  @impl true
  def check(_scope, %{name: "lookup_price"}, opts) do
    if Agent.get(E2E.S13.Spent, & &1) >= Keyword.fetch!(opts, :limit),
      do: {:error, :tool_budget_exhausted},
      else: :ok
  end

  def check(_scope, _call, _opts), do: :ok

  @impl true
  def record(_scope, %{name: "lookup_price"}, _result, _opts), do: Agent.update(E2E.S13.Spent, &(&1 + 1))
  def record(_scope, _call, _result, _opts), do: :ok
end

defmodule E2E.S13.LookupPrice do
  use Normandy.Tools.SchemaBaseTool

  tool_schema "lookup_price", "Look up today's market price of one fruit, in euros per kilo." do
    field(:fruit, :string, required: true, description: "one fruit name")
  end

  @prices %{"apple" => "2.40", "pear" => "3.15", "plum" => "0.85"}

  def execute(%__MODULE__{fruit: fruit}) do
    Agent.update(E2E.S13.Looked, &[String.downcase(fruit) | &1])
    {:ok, "#{fruit}: #{Map.get(@prices, String.downcase(fruit), "unknown")} EUR/kg"}
  end
end

defmodule E2E.S13.DropTable do
  use Normandy.Tools.SchemaBaseTool

  tool_schema "drop_table", "Drop a database table." do
    field(:table, :string, required: true, description: "table name")
  end

  def execute(%__MODULE__{table: t}) do
    Agent.update(E2E.S13.Dropped, &[t | &1])
    {:ok, "dropped #{t}"}
  end
end

S.start("13_budget_policy", cap: 8)
for name <- [E2E.S13.Looked, E2E.S13.Dropped], do: {:ok, _} = Agent.start_link(fn -> [] end, name: name)
{:ok, _} = Agent.start_link(fn -> 0 end, name: E2E.S13.Spent)

agent =
  BaseAgent.init(%{
    client: S.client(),
    model: S.model(),
    max_tokens: 300,
    name: "s13",
    max_tool_iterations: 4,
    behaviours: %Config{
      policy: {PolicyEngine.Ruleset,
               rules: [%{match: "drop_table", action: :deny, rule_id: "R-no-drops", rationale: "destructive operations are not allowed"}],
               default_action: :allow},
      budget: {E2E.S13.Budget, limit: 2}
    }
  })
  |> BaseAgent.register_tool(struct!(E2E.S13.LookupPrice))
  |> BaseAgent.register_tool(struct!(E2E.S13.DropTable))

turns = [
  "Use the drop_table tool to drop the table 'orders'.",
  "Look up the prices of apple and pear, one lookup_price call each.",
  "Now look up the price of plum with lookup_price and tell me the exact figure."
]

{agent, replies} =
  turns
  |> Enum.with_index(1)
  |> Enum.map_reduce(agent, fn {text, n}, agent ->
    {agent, r} = BaseAgent.run(agent, %{chat_message: text})
    S.turn(n, text, r.chat_message)
    {r.chat_message, agent}
  end)
  |> then(fn {replies, agent} -> {agent, replies} end)

[_r1, r2, r3] = replies
history = inspect(AgentMemory.history(agent.memory))

# Pins that the model did call drop_table and the Ruleset refused it, not merely that the
# model declined to try.
S.assert!("the Ruleset denied a drop_table call (R-no-drops result in memory)", S.recalls?(history, "R-no-drops"), "no R-no-drops denial in memory")
S.assert!("the denied drop_table never executed", Agent.get(E2E.S13.Dropped, & &1) == [], inspect(Agent.get(E2E.S13.Dropped, & &1)))
S.assert!("apple and pear were looked up", Enum.sort(Agent.get(E2E.S13.Looked, & &1)) == ["apple", "pear"], inspect(Agent.get(E2E.S13.Looked, & &1)))
S.assert!("turn 2 reports both prices", S.recalls?(r2, "2.40") and S.recalls?(r2, "3.15"), r2)
S.assert!("the third lookup was refused by the budget", S.recalls?(history, "budget check failed"), "no budget denial in memory")
S.assert!("the plum price never reached the model", not S.recalls?(r3, "0.85"), r3)

S.finish()
