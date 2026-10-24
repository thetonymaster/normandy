defmodule Normandy.Behaviours.Compactor.WindowManager do
  @moduledoc """
  Opt-in Compactor that wraps `Normandy.Context.WindowManager`'s truncation
  strategies (`:oldest_first | :summarize`).

  Triggered at the turn's `:steering` boundary: builds a `WindowManager` sized to the
  model's context window (`ctx.window`, unless `opts` pins `:context_window`) and estimates
  the conversation by summing each message's estimate cached on its entry
  (`Normandy.Components.AgentMemory.Entry`). Under budget that one estimate is all it
  does and nothing changes, so a mid-round boundary (`ctx.mid_round`) leaves the open tool
  round and its thinking alone until the conversation no longer fits. Over budget it
  delegates to `WindowManager.truncate_conversation/2`, whose strategy
  (`truncate_oldest_first` among them) and the result's `tokens_after` sum the cached
  estimates again, and a compaction strips the kept messages' thinking (see "Compacting
  mid-round" in `Normandy.Behaviours.Compactor`).

  Options: `:context_window` pins the window (and skips the model catalog lookup);
  `:reserved_tokens` is the answer's room, by default the agent's `max_tokens`; a reserve
  at or above the window raises `ArgumentError`; `:strategy` goes to
  `WindowManager.new/1`; `:summary_max_tokens` is the `:summarize` strategy's summary
  budget (default: the agent's `max_tokens`). The 1.x name `:max_tokens` for the pin
  raises `ArgumentError`.
  Any other key raises `ArgumentError` when the agent is built (`BaseAgent.init/1`, DSL
  `new/1`) or its template is rebuilt.
  The `:summarize` strategy needs `acc.client`; if summarization fails it returns the
  original `acc` with `%{compacted: false, error: reason}` rather than crashing the turn.
  Its meta carries `:dropped`, the removed entries (see `Normandy.Behaviours.Compactor`).
  """
  @behaviour Normandy.Behaviours.Compactor

  alias Normandy.Components.AgentMemory
  alias Normandy.Context.WindowManager, as: WM
  alias Normandy.Options

  @opts_schema NimbleOptions.new!(
                 context_window: [
                   type: :pos_integer,
                   doc: "Pins the context window instead of asking the model catalog."
                 ],
                 reserved_tokens: [
                   type: :non_neg_integer,
                   doc:
                     "Tokens kept free for the answer (default: the agent's `max_tokens`). " <>
                       "Must be smaller than the context window."
                 ],
                 # The type and the default are Context.WindowManager.new/1's (one source).
                 strategy: [
                   type:
                     Normandy.Context.WindowManager.__opts_schema__(:new).schema
                     |> Keyword.fetch!(:strategy)
                     |> Keyword.fetch!(:type),
                   doc:
                     "The truncation strategy (default: `Normandy.Context.WindowManager.new/1`'s)."
                 ],
                 summary_max_tokens: [
                   type: {:or, [:pos_integer, nil]},
                   default: nil,
                   doc:
                     "`max_tokens` of the `:summarize` strategy's summary call (default `nil`: " <>
                       "the agent's `max_tokens`, else 16_000). Thinking shares it."
                 ]
               )

  @doc """
  Checks the options (`Normandy.Behaviours.Compactor` callback). `BaseAgent.init/1` and
  `ConfigTemplate.rebuild/3` call it, so a typo surfaces where the config is made, not
  mid-turn. The 1.x `:max_tokens` pin raises with a pointer to `:context_window`.
  """
  @impl Normandy.Behaviours.Compactor
  @spec validate_opts!(keyword(), {module(), atom(), arity()}) :: keyword()
  def validate_opts!(opts, {mod, fun, arity} = entry) do
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, :max_tokens) do
      raise ArgumentError,
            "#{inspect(mod)}.#{fun}/#{arity}: the :max_tokens option " <>
              "of #{inspect(__MODULE__)} was renamed to :context_window " <>
              "in 2.0; see MIGRATING-2.0.md §22"
    end

    Options.validate!(opts, @opts_schema, entry)
  end

  @doc "Always `true`: the strategies size against the model's context window."
  @impl Normandy.Behaviours.Compactor
  @spec needs_window?(keyword()) :: true
  def needs_window?(_opts), do: true

  @impl true
  def maybe_compact(acc, %{window: window}, opts) do
    case build_manager(window, opts, acc) do
      nil ->
        {acc, %{compacted: false, reason: :no_window}}

      %WM{} = manager ->
        run(acc, manager)
    end
  end

  # A pinned :context_window wins; otherwise the model's window from ctx; with neither
  # there is nothing to size against, so the compactor skips. The answer's room is the
  # agent's max_tokens unless opts pins :reserved_tokens; it is read only when a manager
  # is actually built.
  defp build_manager(window, opts, acc) do
    :ok = reject_max_tokens!(opts)

    case Keyword.fetch(opts, :context_window) do
      {:ok, pinned} -> checked_manager(pinned, Keyword.delete(opts, :context_window), acc)
      :error when is_integer(window) -> checked_manager(window, opts, acc)
      :error -> nil
    end
  end

  # 1.x and the 2.0 betas pinned the window with :max_tokens, the name the agent uses
  # for the answer's limit. Read silently, it would now be ignored.
  defp reject_max_tokens!(opts) do
    if Keyword.has_key?(opts, :max_tokens) do
      raise ArgumentError,
            "Compactor.WindowManager: the :max_tokens option was renamed to :context_window " <>
              "in 2.0 (the model's context window in tokens); see MIGRATING-2.0.md §22"
    end

    :ok
  end

  defp checked_manager(window, opts, acc) do
    unless is_integer(window) and window > 0 do
      raise ArgumentError,
            "Compactor.WindowManager: :context_window must be a positive integer (the " <>
              "model's context window in tokens), got: #{inspect(window)}"
    end

    reserved = Keyword.get_lazy(opts, :reserved_tokens, fn -> agent_max_tokens!(acc) end)

    unless is_integer(reserved) and reserved >= 0 do
      raise ArgumentError,
            "Compactor.WindowManager: :reserved_tokens must be a non-negative integer, " <>
              "got: #{inspect(reserved)}"
    end

    if reserved >= window do
      raise ArgumentError,
            "Compactor.WindowManager: reserved_tokens (#{reserved}) must be smaller than " <>
              "the context window (#{window}); lower the agent's max_tokens or pass " <>
              ":reserved_tokens in the compactor opts"
    end

    WM.new(
      [max_tokens: window, reserved_tokens: reserved] ++
        Keyword.take(opts, [:strategy, :summary_max_tokens])
    )
  end

  # The default reserve: the agent's max_tokens. A real agent config always has a
  # positive one (init/1 and ConfigTemplate.rebuild/3 check it).
  defp agent_max_tokens!(%{max_tokens: n}) when is_integer(n) and n > 0, do: n

  defp agent_max_tokens!(%{max_tokens: other}) do
    raise ArgumentError,
          "Compactor.WindowManager: the agent's max_tokens is the default :reserved_tokens " <>
            "and must be a positive integer, got: #{inspect(other)}; set it, or pass " <>
            ":reserved_tokens in the compactor opts"
  end

  defp agent_max_tokens!(_acc) do
    raise ArgumentError,
          "Compactor.WindowManager: the agent config has no :max_tokens to reserve for the " <>
            "answer; pass :reserved_tokens in the compactor opts"
  end

  # One estimate (a sum of the entries' cached estimates). Within budget nothing else
  # runs: the meta is the no-op one, with no dropped entries, so after_compact does not run.
  defp run(acc, manager) do
    before = WM.estimate_conversation_tokens(acc.memory)

    if before <= manager.max_tokens - manager.reserved_tokens do
      {acc,
       %{
         compacted: false,
         tokens_before: before,
         tokens_after: before,
         tokens_removed: 0,
         strategy: manager.strategy,
         dropped: []
       }}
    else
      compact(acc, manager, before)
    end
  end

  defp compact(acc, manager, before) do
    case WM.truncate_conversation(acc, manager) do
      {:ok, acc2} ->
        after_tokens = WM.estimate_conversation_tokens(acc2.memory)
        dropped = dropped_entries(acc.memory, acc2.memory)

        {acc2,
         %{
           compacted: after_tokens < before,
           tokens_before: before,
           tokens_after: after_tokens,
           tokens_removed: tokens_removed_this_turn(acc.memory, dropped),
           strategy: manager.strategy,
           dropped: dropped
         }}

      {:error, reason} ->
        {acc, %{compacted: false, error: reason}}
    end
  end

  # The entries of `before` that `after` no longer holds, oldest first. Every strategy
  # keeps a kept message's entry id and gives a summary a new one, so this is exactly
  # what compaction removed.
  defp dropped_entries(before_memory, after_memory) do
    kept = MapSet.new(AgentMemory.entry_chain(after_memory), & &1.id)
    Enum.reject(AgentMemory.entry_chain(before_memory), &MapSet.member?(kept, &1.id))
  end

  # Gross estimated tokens of the dropped messages that belong to the current turn:
  # what the task budget's `remaining` must subtract (Anthropic task-budgets doc,
  # "Carrying a budget across compaction"). Earlier turns were never this task's
  # spend, and a summary is new, so it is never dropped. Each message counts its
  # cached estimate (what the model is sent for it, plus 10 tokens of per-message
  # overhead), the same estimate `tokens_before` sums; it approximates, it is not the
  # exact request payload.
  defp tokens_removed_this_turn(before_memory, dropped) do
    turn_id = AgentMemory.get_current_turn_id(before_memory)

    dropped
    |> Enum.filter(&(&1.turn_id == turn_id))
    |> Enum.map(&AgentMemory.entry_tokens/1)
    |> Enum.sum()
  end
end
