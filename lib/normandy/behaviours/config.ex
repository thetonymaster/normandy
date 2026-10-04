defmodule Normandy.Behaviours.Config do
  @moduledoc """
  Explicit, per-agent selection of the pluggable behaviours.

  One `{module, opts}` ref per behaviour plus the two first-class hook lists.
  `hooks` is an ordered list of `Normandy.Behaviours.Hooks` entries, persisted with the refs.
  Carried on `BaseAgentConfig.behaviours`; defaults to the all-defaults bundle,
  so the "everything off" path is observably identical to today.

  `to_pipeline/1` adapts the **dispatch-path** slots (`policy`, `budget`,
  `before_hooks`, `after_hooks`, and the `before_tool`/`after_tool` callbacks of `hooks`) into a `%Normandy.Agents.Dispatch.Pipeline{}`.
  Building it here (not on `Dispatch`) keeps the Phase 1 chokepoint untouched —
  the dependency points Phase 2 → Phase 1. The `credential`, `compactor`,
  `model_catalog`, `session_store`, and `session_registry` slots are not
  dispatch-path concerns and are not placed on the pipeline. `compactor` selects
  the `:steering`-boundary compaction strategy (Phase 5); `session_store`
  selects where session entries / turn state persist; it is wired here but not
  yet consumed by the turn loop (Phase 4 reads it).
  """

  alias Normandy.Agents.Dispatch.Pipeline
  alias Normandy.Behaviours.BudgetTracker
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.CredentialProvider
  alias Normandy.Behaviours.ModelCatalog
  alias Normandy.Behaviours.PolicyEngine
  alias Normandy.Behaviours.SessionRegistry
  alias Normandy.Behaviours.SessionStore
  alias Normandy.Hooks.Runner
  alias Normandy.Tools.Context
  alias Normandy.Tools.Executor

  @type ref :: {module(), keyword()}
  @type hook :: (term(), term() -> term()) | (term(), term(), term() -> term())
  @type t :: %__MODULE__{
          policy: ref(),
          budget: ref(),
          before_hooks: [hook()],
          after_hooks: [hook()],
          hooks: [Normandy.Behaviours.Hooks.entry()],
          credential: ref(),
          compactor: ref(),
          model_catalog: ref(),
          session_store: ref(),
          session_registry: ref()
        }

  defstruct policy: {PolicyEngine.AllowAll, []},
            budget: {BudgetTracker.NoOp, []},
            before_hooks: [],
            after_hooks: [],
            hooks: [],
            credential: {CredentialProvider.FromClient, []},
            compactor: {Compactor.NoOp, []},
            model_catalog: {ModelCatalog.ModelsAPI, []},
            session_store: {SessionStore.InMemory, []},
            session_registry: {SessionRegistry.Native, []}

  @doc """
  Builds a `%Dispatch.Pipeline{}` from the dispatch-path slots of the bundle.

  `nil` resolves to the default bundle. `execute_fn` is set to the bare executor, which
  passes the call's `%Normandy.Tools.Context{}` (matching `Dispatch.default_pipeline/0`);
  callers that need telemetry (e.g. `BaseAgent`) override `execute_fn` after building.
  """
  @spec to_pipeline(t() | nil) :: Pipeline.t()
  def to_pipeline(nil), do: to_pipeline(%__MODULE__{})

  def to_pipeline(%__MODULE__{} = bundle) do
    {policy_mod, policy_opts} = bundle.policy
    {budget_mod, budget_opts} = bundle.budget

    %Pipeline{
      before_hooks: module_before_tool(bundle) ++ bundle.before_hooks,
      after_hooks: bundle.after_hooks,
      after_tool: module_after_tool(bundle),
      policy_fn: fn config, call, tool ->
        policy_mod.check(call, %{config: config, tool: tool, opts: policy_opts})
      end,
      budget_check_fn: fn config, call ->
        budget_mod.check(scope(config), call, budget_opts)
      end,
      budget_record_fn: fn config, call, result ->
        budget_mod.record(scope(config), call, result, budget_opts)
      end,
      execute_fn: fn config, tool, _name, call ->
        Executor.execute_tool(tool, context: Context.build(config, call))
      end
    }
  end

  defp scope(config) do
    %{agent: Map.get(config, :name), model: Map.get(config, :model)}
  end

  # Hook modules run ahead of the function hooks: one adapter at the head of
  # before_hooks (a module halt skips the functions, since Dispatch stops at the first
  # halt) and the after_tool slot, which Dispatch applies to every result. The adapter
  # runs the hooks of the config the call is dispatched with (the agent's, whose
  # behaviours this bundle is). No entry exporting the callback, no adapter: the
  # pipeline is exactly what it was before hooks.
  defp module_before_tool(bundle) do
    if Runner.handles?(%{behaviours: bundle}, :before_tool),
      do: [fn config, call -> Runner.before_tool(config, call) end],
      else: []
  end

  defp module_after_tool(bundle) do
    if Runner.handles?(%{behaviours: bundle}, :after_tool),
      do: fn config, call, result -> Runner.after_tool(config, call, result) end,
      else: nil
  end
end
