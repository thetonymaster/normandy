# e2e/10_coordination.exs — a pool of agent processes over three rounds, then hierarchical and sequential runs.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Components.{AgentMemory, PromptSpecification}

alias Normandy.Coordination.{
  AgentPool,
  AgentProcess,
  HierarchicalCoordinator,
  SequentialOrchestrator
}

defmodule E2E.S10.Plan do
  use Normandy.Schema

  io_schema "manager's delegation plan" do
    field(:chat_message, :string, description: "short note to the user", required: true)

    field(:delegation_plan, {:array, :string},
      description: "exactly two subtasks, one per worker",
      required: true
    )
  end
end

S.start("10_coordination", cap: 14)

base = %{client: S.client(), model: S.model(), max_tokens: 150}

reply = fn
  {:ok, %{chat_message: m}} -> m
  {:ok, other} -> inspect(other)
  other -> inspect(other)
end

S.narrate("AgentPool of 2 processes, three rounds of two concurrent transactions.")

pool_config =
  Map.merge(base, %{
    name: "s10-pool",
    prompt_specification: %PromptSpecification{
      background: [
        "You are a helpful assistant in one ongoing conversation; remember what the user tells you."
      ]
    }
  })

{:ok, pool} = AgentPool.start_link(agent_config: pool_config, size: 2, max_overflow: 0)

rounds =
  for round <- 1..3 do
    tasks =
      for _worker <- 1..2 do
        Task.async(fn ->
          AgentPool.transaction(pool, fn pid ->
            text =
              "Round #{round}: remember the number #{round * 11}. Then list every number I have asked you to remember so far, comma separated."

            {pid, reply.(AgentProcess.run(pid, text))}
          end)
        end)
      end

    results = Task.await_many(tasks, 60_000)

    Enum.each(results, fn {:ok, {pid, text}} ->
      IO.puts("  [round #{round}] #{inspect(pid)}: #{text}")
    end)

    Enum.map(results, fn {:ok, r} -> r end)
  end

pids_per_round = Enum.map(rounds, fn r -> r |> Enum.map(&elem(&1, 0)) |> MapSet.new() end)

S.assert!(
  "each round used two distinct workers",
  Enum.all?(pids_per_round, &(MapSet.size(&1) == 2)),
  inspect(pids_per_round)
)

S.assert!(
  "the same two workers served every round",
  Enum.uniq(pids_per_round) |> length() == 1,
  inspect(pids_per_round)
)

for {pid, text} <- List.last(rounds) do
  S.assert!(
    "worker #{inspect(pid)} remembers all three rounds",
    Enum.all?(["11", "22", "33"], &S.recalls?(text, &1)),
    text
  )

  count = pid |> AgentProcess.get_agent() |> Map.fetch!(:memory) |> AgentMemory.count_messages()
  S.assert!("worker #{inspect(pid)} memory grew to 6 messages", count == 6, "#{count}")
end

S.narrate("HierarchicalCoordinator: a manager splits a task across two workers and aggregates.")

manager =
  BaseAgent.init(
    Map.merge(base, %{
      name: "s10-manager",
      max_tokens: 300,
      output_schema: struct!(E2E.S10.Plan),
      prompt_specification: %PromptSpecification{
        background: [
          "You plan work for exactly two workers and later combine their answers.",
          "When combining, put each worker's fact itself into chat_message; never just say that you combined them."
        ]
      }
    })
  )

worker = fn name -> BaseAgent.init(Map.put(base, :name, name)) end

coord =
  HierarchicalCoordinator.new(
    manager: manager,
    workers: [%{id: "w1", agent: worker.("s10-w1")}, %{id: "w2", agent: worker.("s10-w2")}],
    delegation_strategy: :round_robin
  )

before = S.calls()

{:ok, combined} =
  HierarchicalCoordinator.execute(coord, "Give one fun fact about owls and one about octopuses.",
    manager_prompt: "Split this into one subtask per animal."
  )

IO.puts("  combined: #{inspect(combined) |> String.slice(0, 400)}")

S.assert!(
  "hierarchical run made manager + 2 workers + aggregation requests",
  S.calls() - before >= 4,
  "#{S.calls() - before}"
)

S.assert!(
  "the combined answer mentions both animals",
  S.recalls?(inspect(combined), "owl") and S.recalls?(inspect(combined), "octop"),
  inspect(combined)
)

S.narrate("SequentialOrchestrator: translate, then name the translation's language.")

specs = [
  %{
    id: "translate",
    agent:
      BaseAgent.init(
        Map.merge(base, %{
          name: "s10-translate",
          prompt_specification: %PromptSpecification{
            background: ["Translate the user's text into Spanish. Output only the translation."]
          }
        })
      )
  },
  %{
    id: "count",
    agent:
      BaseAgent.init(
        Map.merge(base, %{
          name: "s10-count",
          prompt_specification: %PromptSpecification{
            background: ["Reply with the language of the user's text, one word in English."]
          }
        })
      )
  }
]

{:ok, %{success: true, results: [first, second], errors: []}} =
  SequentialOrchestrator.execute(specs, "The library opens at nine in the morning.", [])

IO.puts("  step 1: #{inspect(first) |> String.slice(0, 200)}")
IO.puts("  step 2: #{inspect(second) |> String.slice(0, 200)}")

S.assert!(
  "step 2 received step 1's Spanish output",
  S.recalls?(inspect(second), "spanish"),
  inspect(second)
)

S.finish()
