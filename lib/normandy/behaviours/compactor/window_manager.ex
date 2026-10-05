defmodule Normandy.Behaviours.Compactor.WindowManager do
  @moduledoc """
  Opt-in Compactor that wraps `Normandy.Context.WindowManager`'s truncation
  strategies (`:oldest_first | :sliding_window | :summarize`).

  Triggered at the turn's `:steering` boundary: builds a `WindowManager` whose
  `max_tokens` is the model's context window (from `ctx.window`, unless `opts`
  pins an explicit `:max_tokens`), then delegates to
  `WindowManager.ensure_within_limit/2` — a no-op when already under budget.

  `opts` flow straight to `WindowManager.new/1` (`:strategy`, `:reserved_tokens`,
  `:max_tokens`). `:reserved_tokens` defaults to the agent's `max_tokens`; a reserve
  at or above the context window raises `ArgumentError`. The `:summarize` strategy needs `acc.client`; if summarization
  fails it returns the original `acc` with `%{compacted: false, error: reason}`
  rather than crashing the turn. Its meta carries `:dropped`, the removed entries
  (see `Normandy.Behaviours.Compactor`).
  """
  @behaviour Normandy.Behaviours.Compactor

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Context.WindowManager, as: WM

  @impl true
  def maybe_compact(acc, %{window: window}, opts) do
    case build_manager(window, opts, acc) do
      nil ->
        {acc, %{compacted: false, reason: :no_window}}

      %WM{} = manager ->
        run(acc, manager)
    end
  end

  # Honour an explicit opts :max_tokens; otherwise use the model window; if
  # neither is known, skip (no trigger basis). The answer's room is the agent's
  # max_tokens unless opts pins :reserved_tokens; it is read only when a manager
  # is actually built.
  defp build_manager(window, opts, acc) do
    cond do
      Keyword.has_key?(opts, :max_tokens) -> checked_manager(opts, acc)
      is_integer(window) -> checked_manager(Keyword.put(opts, :max_tokens, window), acc)
      true -> nil
    end
  end

  defp checked_manager(opts, acc) do
    opts = Keyword.put_new_lazy(opts, :reserved_tokens, fn -> Map.fetch!(acc, :max_tokens) end)
    reserved = Keyword.fetch!(opts, :reserved_tokens)
    window = Keyword.fetch!(opts, :max_tokens)

    if reserved >= window do
      raise ArgumentError,
            "Compactor.WindowManager: reserved_tokens (#{reserved}) must be smaller than " <>
              "the context window (#{window}); lower the agent's max_tokens or pass " <>
              ":reserved_tokens in the compactor opts"
    end

    WM.new(opts)
  end

  defp run(acc, manager) do
    before = WM.estimate_conversation_tokens(acc.memory)

    case WM.ensure_within_limit(acc, manager) do
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
  # spend, and a summary is new, so it is never dropped. Each message's content is
  # serialized with `BaseIOSchema.to_json/1` for the estimate, plus 10 tokens of
  # per-message overhead; this approximates, it is not the exact request payload.
  defp tokens_removed_this_turn(before_memory, dropped) do
    turn_id = AgentMemory.get_current_turn_id(before_memory)

    dropped
    |> Enum.filter(&(&1.turn_id == turn_id))
    |> Enum.map(&(WM.estimate_message_content_tokens(BaseIOSchema.to_json(&1.content)) + 10))
    |> Enum.sum()
  end
end
