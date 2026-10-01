defmodule Normandy.Behaviours.ModelCatalog do
  @moduledoc """
  Contract for model capability/limit lookup.

  `BaseAgent.compact_turn_memory/3` reads `context_window/2` to size the
  `:steering`-boundary compaction. The default impl, `ModelsAPI`, asks the
  Anthropic Models API at runtime, so new models need no Normandy release.

  Callbacks receive the `opts` from the `{module, opts}` reference in
  `Normandy.Behaviours.Config`. BaseAgent adds `:client` (a Claudio client built
  from the agent's `Normandy.LLM.ClaudioAdapter`) when the reference sets none.
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
    """
    @behaviour Normandy.Behaviours.ModelCatalog

    @impl true
    defdelegate context_window(model, opts), to: Normandy.Behaviours.ModelCatalog.ModelsAPI
  end
end
