defmodule Normandy.Behaviours.Compactor.WindowManager do
  @moduledoc """
  Opt-in Compactor that wraps `Normandy.Context.WindowManager`'s truncation
  strategies (`:oldest_first | :sliding_window | :summarize`).

  Triggered at the turn's `:steering` boundary: builds a `WindowManager` whose
  `max_tokens` is the model's context window (from `ctx.window`, unless `opts`
  pins an explicit `:max_tokens`), then delegates to
  `WindowManager.ensure_within_limit/2` — a no-op when already under budget.

  `opts` flow straight to `WindowManager.new/1` (`:strategy`, `:reserved_tokens`,
  `:max_tokens`). The `:summarize` strategy needs `acc.client`; if summarization
  fails it returns the original `acc` with `%{compacted: false, error: reason}`
  rather than crashing the turn.
  """
  @behaviour Normandy.Behaviours.Compactor

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Context.WindowManager, as: WM

  @impl true
  def maybe_compact(acc, %{window: window}, opts) do
    case build_manager(window, opts) do
      nil ->
        {acc, %{compacted: false, reason: :no_window}}

      %WM{} = manager ->
        run(acc, manager)
    end
  end

  # Honour an explicit opts :max_tokens; otherwise use the model window; if
  # neither is known, skip (no trigger basis).
  defp build_manager(window, opts) do
    cond do
      Keyword.has_key?(opts, :max_tokens) -> WM.new(opts)
      is_integer(window) -> WM.new(Keyword.put(opts, :max_tokens, window))
      true -> nil
    end
  end

  defp run(acc, manager) do
    before = WM.estimate_conversation_tokens(acc.memory)

    case WM.ensure_within_limit(acc, manager) do
      {:ok, acc2} ->
        after_tokens = WM.estimate_conversation_tokens(acc2.memory)

        {acc2,
         %{
           compacted: after_tokens < before,
           tokens_before: before,
           tokens_after: after_tokens,
           tokens_removed: tokens_removed_this_turn(acc.memory, acc2.memory),
           strategy: manager.strategy
         }}

      {:error, reason} ->
        {acc, %{compacted: false, error: reason}}
    end
  end

  # Gross estimated tokens of the messages compaction removed that belong to the
  # current turn: what the task-budget `remaining` must subtract (Anthropic
  # task-budgets doc, "Carrying a budget across compaction"). Earlier turns were
  # never this task's spend, and a summary is new in `after`, so it's never in the
  # removed set. Keyed on to_json(content): kept content is stored in its JSON form.
  defp tokens_removed_this_turn(before_memory, after_memory) do
    turn_id = AgentMemory.get_current_turn_id(before_memory)
    removed = message_keys(before_memory) -- message_keys(after_memory)

    removed
    |> Enum.filter(fn {id, _role, _content} -> id == turn_id end)
    |> Enum.map(fn {_id, _role, content} -> WM.estimate_message_content_tokens(content) + 10 end)
    |> Enum.sum()
  end

  defp message_keys(memory) do
    for msg <- AgentMemory.messages(memory),
        do: {msg.turn_id, msg.role, BaseIOSchema.to_json(msg.content)}
  end
end
