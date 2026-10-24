defmodule Normandy.Behaviours.BudgetTracker do
  @moduledoc """
  Contract for budget gating and accounting around tool calls.

  `check/3` is a pre-spend gate (returns `:ok` to proceed or `{:error, reason}`
  to deny before executing the tool call); `record/4` accounts for the call's
  result afterwards. `scope` identifies the budget owner
  (`%{agent: name, model: model}`). Agents without a `:name` share one scope per
  model, so give each agent whose spend you track its own name. `opts` is the `opts` half of the
  `{module, opts}` ref in `Normandy.Behaviours.Config` (limits, a store
  handle, a name). The default impl `NoOp` preserves current (untracked)
  behavior.
  """

  @type scope :: term()

  @doc """
  Decides before a tool call whether it may run. Return `:ok` to run it, or
  `{:error, reason}` to refuse it.

  A refused call is not run and not recorded; the model receives an error result that says
  the tool budget is used up, with `reason` appended when it is a non-empty string. `scope`
  is `%{agent: name, model: model}`, `call` the `Normandy.Components.ToolCall`.
  """
  @callback check(scope(), call :: term(), opts :: keyword()) :: :ok | {:error, term()}
  @doc """
  Accounts for a tool call after it ran, with its `Normandy.Components.ToolResult`.

  Return `:ok`. It is called for each call that passed `check/3` and ran, including one that
  returned an error result, and not for a refused call.
  """
  @callback record(scope(), call :: term(), result :: term(), opts :: keyword()) :: :ok

  defmodule NoOp do
    @moduledoc "Default BudgetTracker: no gating, no accounting (back-compat)."
    @behaviour Normandy.Behaviours.BudgetTracker

    @impl true
    def check(_scope, _call, _opts), do: :ok

    @impl true
    def record(_scope, _call, _result, _opts), do: :ok
  end
end
