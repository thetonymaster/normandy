defmodule Normandy.Behaviours.Config do
  @moduledoc """
  Explicit, per-agent selection of the pluggable behaviours.

  One `{module, opts}` ref per behaviour plus the two first-class hook lists.
  Carried on `BaseAgentConfig.behaviours`; defaults to the all-defaults bundle,
  so the "everything off" path is observably identical to today.

  `to_pipeline/1` adapts the **dispatch-path** slots (`policy`, `budget`,
  `before_hooks`, `after_hooks`) into a `%Normandy.Agents.Dispatch.Pipeline{}`.
  Building it here (not on `Dispatch`) keeps the Phase 1 chokepoint untouched —
  the dependency points Phase 2 → Phase 1. The `credential`, `model_catalog`, and `session_store` slots are not
  dispatch-path concerns and are not placed on the pipeline. `session_store`
  selects where session entries / turn state persist; it is wired here but not yet
  consumed by the turn loop (Phase 4 reads it).
  """

  alias Normandy.Agents.Dispatch.Pipeline
  alias Normandy.Behaviours.BudgetTracker
  alias Normandy.Behaviours.CredentialProvider
  alias Normandy.Behaviours.ModelCatalog
  alias Normandy.Behaviours.PolicyEngine
  alias Normandy.Behaviours.SessionStore
  alias Normandy.Tools.Executor

  @type ref :: {module(), keyword()}
  @type hook :: (term(), term() -> term()) | (term(), term(), term() -> term())
  @type t :: %__MODULE__{
          policy: ref(),
          budget: ref(),
          before_hooks: [hook()],
          after_hooks: [hook()],
          credential: ref(),
          model_catalog: ref(),
          session_store: ref()
        }

  defstruct policy: {PolicyEngine.AllowAll, []},
            budget: {BudgetTracker.NoOp, []},
            before_hooks: [],
            after_hooks: [],
            credential: {CredentialProvider.FromClient, []},
            model_catalog: {ModelCatalog.Static, []},
            session_store: {SessionStore.InMemory, []}

  @doc """
  Builds a `%Dispatch.Pipeline{}` from the dispatch-path slots of the bundle.

  `nil` resolves to the default bundle. `execute_fn` is set to the bare executor
  (matching `Dispatch.default_pipeline/0`); callers that need telemetry (e.g.
  `BaseAgent`) override `execute_fn` after building.
  """
  @spec to_pipeline(t() | nil) :: Pipeline.t()
  def to_pipeline(nil), do: to_pipeline(%__MODULE__{})

  def to_pipeline(%__MODULE__{} = bundle) do
    {policy_mod, policy_opts} = bundle.policy
    {budget_mod, _budget_opts} = bundle.budget

    %Pipeline{
      before_hooks: bundle.before_hooks,
      after_hooks: bundle.after_hooks,
      policy_fn: fn config, call, tool ->
        policy_mod.check(call, %{config: config, tool: tool, opts: policy_opts})
      end,
      budget_check_fn: fn config, call ->
        budget_mod.check(scope(config), call)
      end,
      budget_record_fn: fn config, _call, result ->
        budget_mod.record(scope(config), result)
      end,
      execute_fn: fn _config, tool, _name -> Executor.execute_tool(tool) end
    }
  end

  defp scope(config) do
    %{agent: Map.get(config, :name), model: Map.get(config, :model)}
  end
end
