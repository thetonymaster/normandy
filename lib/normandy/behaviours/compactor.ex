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
    * `:window` — the model's context window: the compactor opts' `:context_window`
      when pinned, otherwise resolved through the configured `ModelCatalog`
      (memoised on the agent). `nil` only for the `NoOp` compactor

  Implementations return `{maybe_updated_acc, meta}`. `meta` always carries
  `:compacted` (a boolean); the WindowManager impl adds `:tokens_before`,
  `:tokens_after` (whole-memory estimates), `:tokens_removed` (estimated tokens
  of this turn's messages that compaction removed; the task budget's `remaining`
  subtracts it) and `:strategy`. The default impl `NoOp` performs no work and
  preserves current (non-compacting) behavior — the design's default-off
  principle.

  `meta` may also carry `:dropped`: the `%Normandy.Components.AgentMemory.Entry{}`
  structs the compactor removed from the active branch, oldest first, each with the id
  it had in `acc.memory` and its original content. A compactor that fills it keeps each
  kept message under its entry id (`AgentMemory.add_message/4`'s `:id`), so a message is
  reported under one id for as long as the memory lives. `after_compact` hooks
  (`Normandy.Behaviours.Hooks`) run only when `:dropped` is non-empty. The WindowManager
  impl fills it; `NoOp` does not.

  `:dropped` is absent on the error and skip paths (`%{compacted: false, error: reason}`,
  `%{compacted: false}`), so a consumer matches `%{dropped: [_ | _]}` rather than reading
  the key.
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
