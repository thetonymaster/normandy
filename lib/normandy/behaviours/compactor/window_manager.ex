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
      is_integer(window) -> %{WM.new(opts) | max_tokens: window}
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
           strategy: manager.strategy
         }}

      {:error, reason} ->
        {acc, %{compacted: false, error: reason}}
    end
  end
end
