defmodule Normandy.Behaviours.BudgetTracker do
  @moduledoc """
  Contract for budget gating and accounting around tool calls.

  `check/2` is an optional pre-spend gate (returns `:ok` to proceed or
  `{:error, reason}` to deny before executing); `record/2` accounts for actual
  usage after the call. `scope` identifies the budget owner (e.g.
  `%{agent: name, model: model}`); `est`/`usage` are the planned/actual cost
  carriers. The default impl `NoOp` preserves current (untracked) behavior.
  """

  @type scope :: term()

  @callback check(scope(), est :: term()) :: :ok | {:error, term()}
  @callback record(scope(), usage :: term()) :: :ok

  defmodule NoOp do
    @moduledoc "Default BudgetTracker: no gating, no accounting (back-compat)."
    @behaviour Normandy.Behaviours.BudgetTracker

    @impl true
    def check(_scope, _est), do: :ok

    @impl true
    def record(_scope, _usage), do: :ok
  end
end
