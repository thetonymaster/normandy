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
    * `:mid_round` — `false` at the start of a turn, `true` at the boundary after a
      tool batch. There the model's tool round is still open: the next request
      continues it, and its assistant turns go back with their thinking.

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

  ## Compacting mid-round

  A compactor must leave the memory unchanged at a mid-round boundary while the
  conversation still fits the window. When it does compact there, it strips the
  thinking blocks from every message it keeps
  (`Normandy.Components.AgentMemory.drop_thinking/1`): they were produced with the
  full history in place, and the API can reject them after a summary or a cut (it
  validates replayed thinking against what came before it). The open round loses its
  reasoning; it is the documented recovery for keep-tail compaction.
  `Compactor.WindowManager` does both: it compacts only over the window, at any
  boundary, and its strategies strip the kept messages' thinking.
  """

  @type ctx :: %{model: String.t() | nil, window: pos_integer() | nil, mid_round: boolean()}

  @doc """
  Shrinks the conversation in `acc` when it needs to, and returns `{acc, meta}`.

  The turn calls it at the start and after each tool batch, with the running agent config
  as `acc` (the conversation is `acc.memory`), `ctx` (see the moduledoc) and the `opts` of
  the `{module, opts}` ref. Return `acc` unchanged with `%{compacted: false}` to do nothing.
  `meta` always has `:compacted`; the moduledoc lists the other keys. A failed compaction
  returns `acc` and `%{compacted: false, error: reason}`.
  """
  @callback maybe_compact(acc :: term(), ctx(), opts :: keyword()) :: {term(), map()}

  @doc """
  Optional. Checks and normalises the compactor's `opts`; `BaseAgent.init/1` and
  `ConfigTemplate.rebuild/3` call it when the module exports it, so a bad option raises
  `ArgumentError` where the config is made, not mid-turn. Return the validated opts.
  `entry` is that public function's `{module, function, arity}`; pass it to
  `Normandy.Options.validate!/3` so the message names the entry point.
  """
  @callback validate_opts!(opts :: keyword(), entry :: {module(), atom(), arity()}) ::
              keyword()

  @doc """
  Optional. Whether this compactor, given `opts`, sizes against the model's context
  window. When it does and `opts` pin no `:context_window`, the turn resolves the window
  through the configured `ModelCatalog`. A module without the callback is taken to need
  one; `NoOp` does not.
  """
  @callback needs_window?(opts :: keyword()) :: boolean()

  @optional_callbacks validate_opts!: 2, needs_window?: 1

  defmodule NoOp do
    @moduledoc "Default Compactor: never compacts (back-compat, zero cost)."
    @behaviour Normandy.Behaviours.Compactor

    @impl true
    def maybe_compact(acc, _ctx, _opts), do: {acc, %{compacted: false}}

    @impl true
    def needs_window?(_opts), do: false
  end
end
