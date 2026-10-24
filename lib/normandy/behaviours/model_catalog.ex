defmodule Normandy.Behaviours.ModelCatalog do
  @moduledoc """
  Contract for model capability/limit lookup.

  `BaseAgent.Handlers.compact_turn_memory/3` reads `context_window/2` to size the
  `:steering`-boundary compaction. The default impl, `ModelsAPI`, asks the
  Anthropic Models API at runtime, so new models need no Normandy release.

  Callbacks receive the `opts` from the `{module, opts}` reference in
  `Normandy.Behaviours.Config`. BaseAgent adds `:client` (a Claudio client built
  from the agent's `Normandy.LLM.ClaudioAdapter`) when the reference sets none.
  """

  @doc """
  Returns `{:ok, window}`, the model's context window in tokens (a positive integer), or
  `{:error, reason}`.

  The turn calls it when the agent's compactor needs a window and the compactor's opts pin
  none, then keeps the answer on the config per model. Any other `{:ok, value}`, and
  `{:error, reason}`, fail the turn with a `Normandy.ModelCatalogError`.
  """
  @callback context_window(model :: String.t(), opts :: keyword()) ::
              {:ok, pos_integer()} | {:error, term()}

  defmodule ModelsAPI do
    @moduledoc """
    Default ModelCatalog: `GET /v1/models/{model}` through `Claudio.Models.get/2`;
    the context window is the response's `max_input_tokens`.

    Needs `opts[:client]`, a Claudio client (`Req.Request`). It does no caching:
    BaseAgent memoises the window on the agent config.
    """
    @behaviour Normandy.Behaviours.ModelCatalog

    @impl true
    def context_window(model, opts) do
      with {:ok, client} <- fetch_client(opts),
           {:ok, body} <- Claudio.Models.get(client, model) do
        case body do
          %{"max_input_tokens" => n} when is_integer(n) and n > 0 -> {:ok, n}
          _ -> {:error, {:no_context_window, model}}
        end
      end
    end

    defp fetch_client(opts) do
      case Keyword.fetch(opts, :client) do
        {:ok, client} -> {:ok, client}
        :error -> {:error, :no_client}
      end
    end
  end

  defmodule Static do
    @moduledoc """
    Deprecated: use `Normandy.Behaviours.ModelCatalog.ModelsAPI`. Removed in 3.0.

    Kept so agent templates persisted by Normandy 1.x, which name
    `{ModelCatalog.Static, []}`, still decode (`binary_to_term(_, [:safe])` raises
    on an atom that doesn't exist) and still work: `context_window/2` delegates to
    `ModelsAPI`. The old static model table is gone.

    A config that names it logs one deprecation warning per VM, from
    `Normandy.Agents.BaseAgent.init/1` or `Normandy.Agents.ConfigTemplate.rebuild/3`.
    """
    @behaviour Normandy.Behaviours.ModelCatalog

    require Logger

    @warned_key {__MODULE__, :deprecation_warned}

    @impl true
    defdelegate context_window(model, opts), to: Normandy.Behaviours.ModelCatalog.ModelsAPI

    @doc false
    # Logs the deprecation once per VM (a :persistent_term flag); `BaseAgent.init/1` and
    # `ConfigTemplate.rebuild/3` call it for a config whose model_catalog is this module.
    # Two first calls racing may both log; every later call logs nothing.
    @spec warn_deprecated() :: :ok
    def warn_deprecated do
      unless :persistent_term.get(@warned_key, false) do
        :persistent_term.put(@warned_key, true)

        Logger.warning(
          "Normandy.Behaviours.ModelCatalog.Static is deprecated and will be removed in 3.0; " <>
            "set model_catalog: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []}, which " <>
            "answers the same (this warning is logged once per VM)"
        )
      end

      :ok
    end

    @doc false
    # The flag warn_deprecated/0 sets, for tests that check the warning.
    @spec warned_key() :: {__MODULE__, :deprecation_warned}
    def warned_key, do: @warned_key
  end
end
