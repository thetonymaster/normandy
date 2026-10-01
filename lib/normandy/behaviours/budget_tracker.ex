defmodule Normandy.Behaviours.BudgetTracker do
  @moduledoc """
  Contract for budget gating and accounting around tool calls.

  `check/3` is a pre-spend gate (returns `:ok` to proceed or `{:error, reason}`
  to deny before executing the tool call); `record/4` accounts for the call's
  result afterwards. `scope` identifies the budget owner
  (`%{agent: name, model: model}`); `opts` is the `opts` half of the
  `{module, opts}` ref in `Normandy.Behaviours.Config` (limits, a store
  handle, a name). The default impl `NoOp` preserves current (untracked)
  behavior.
  """

  @type scope :: term()

  @callback check(scope(), call :: term(), opts :: keyword()) :: :ok | {:error, term()}
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
