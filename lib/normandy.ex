defmodule Normandy do
  @moduledoc """
  Normandy builds Claude-powered agents in Elixir: typed I/O schemas, tools,
  conversation memory, hooks, guardrails and durable turns.

  Define inputs and outputs with `Normandy.Schema`, then pick an entry point.

  ## Choosing an entry point

  | Use | When | The conversation lives in | Survives a process or node restart |
  |---|---|---|---|
  | `Normandy.Agents.BaseAgent` | You call the agent from your own code: a script, a request handler, a test. `init/1`, then `run/3` or `stream/3`. | the `BaseAgentConfig` value `run/3` returns | no |
  | `Normandy.DSL.Agent` | The same, with the agent declared once in a module (`MyAgent.new/1`, `MyAgent.run/2`). | the `BaseAgentConfig` value | no |
  | `Normandy.Coordination.AgentProcess` | Other processes call one agent, one turn at a time, through a supervised process. | the process | no; with `turn_engine: :server` and a durable store, yes |
  | `Normandy.Agents.Turn.Session` | Conversations outlive a process or a node; tool calls can wait for approval. | a `Normandy.Behaviours.SessionStore` | yes, with a durable store |

  See the guides for tools, memory, hooks and distributed sessions.
  """
end
