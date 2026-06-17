defmodule Normandy.Behaviours.Compactor do
  @moduledoc """
  Contract for context-window compaction at the turn's `:steering` boundary.

  After each tool batch the FSM core (`Normandy.Agents.Turn`) emits a
  `{:maybe_compact, info}` effect and parks in `:steering`. The shell resolves
  that effect by invoking the configured Compactor, which may shrink the running
  conversation (held on `acc`) before the next LLM call, then feeds
  `{:compaction_done, meta}` back into the core.

  `ctx` carries the decision inputs the core cannot compute (it is pure):

    * `:model`  — the model id for this turn
    * `:window` — the model's context-window limit from the configured
      `ModelCatalog`, or `nil` if the model is unknown

  Implementations return `{maybe_updated_acc, meta}`. `meta` always carries
  `:compacted` (a boolean); the WindowManager impl adds `:tokens_before`,
  `:tokens_after`, and `:strategy`. The default impl `NoOp` performs no work and
  preserves current (non-compacting) behavior — the design's default-off
  principle.
  """

  @type ctx :: %{model: String.t() | nil, window: pos_integer() | nil}

  @callback maybe_compact(acc :: term(), ctx(), opts :: keyword()) :: {term(), map()}

  defmodule NoOp do
    @moduledoc "Default Compactor: never compacts (back-compat, zero cost)."
    @behaviour Normandy.Behaviours.Compactor

    @impl true
    def maybe_compact(acc, _ctx, _opts), do: {acc, %{compacted: false}}
  end
end
