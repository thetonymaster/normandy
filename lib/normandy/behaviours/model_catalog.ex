defmodule Normandy.Behaviours.ModelCatalog do
  @moduledoc """
  Contract for model capability/limit lookup.

  The default impl `Static` is the canonical home for the context-window limits
  that previously lived hardcoded on `Normandy.Context.WindowManager`. Phase 2
  consumption is `WindowManager` sourcing its limits here; Phase 5 adds turn-loop
  consumption — `BaseAgent.compact_turn_memory/3` reads `context_window/1` to
  decide the `:steering`-boundary compaction trigger.
  """

  @callback get(model :: String.t()) :: {:ok, map()} | :error
  @callback supports?(model :: String.t(), capability :: atom()) :: boolean()
  @callback context_window(model :: String.t()) :: pos_integer() | nil

  defmodule Static do
    @moduledoc """
    Default ModelCatalog: a fixed catalog absorbing `WindowManager`'s hardcoded
    context-window limits. All listed models are tool/vision/streaming-capable.
    """
    @behaviour Normandy.Behaviours.ModelCatalog

    @capabilities [:tools, :vision, :streaming]

    @limits %{
      "claude-haiku-4-5-20251001" => 200_000,
      "claude-3-5-sonnet-20241022" => 200_000,
      "claude-3-5-haiku-20241022" => 200_000,
      "claude-3-opus-20240229" => 200_000,
      "claude-3-sonnet-20240229" => 200_000,
      "claude-3-haiku-20240307" => 200_000
    }

    @doc "The canonical context-window limits map (single source of truth)."
    @spec limits() :: %{String.t() => pos_integer()}
    def limits, do: @limits

    @impl true
    def get(model) do
      case Map.fetch(@limits, model) do
        {:ok, window} -> {:ok, %{context_window: window, capabilities: @capabilities}}
        :error -> :error
      end
    end

    @impl true
    def supports?(model, capability) do
      case get(model) do
        {:ok, %{capabilities: caps}} -> capability in caps
        :error -> false
      end
    end

    @impl true
    def context_window(model) do
      case Map.fetch(@limits, model) do
        {:ok, window} -> window
        :error -> nil
      end
    end
  end
end
