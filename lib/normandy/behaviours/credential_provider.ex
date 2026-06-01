defmodule Normandy.Behaviours.CredentialProvider do
  @moduledoc """
  Contract for resolving an LLM provider token.

  Defined and defaulted in Phase 2; its consumption at the `Model.converse`
  boundary is deferred (the token still flows through `config.client` today).
  The default impl `FromClient` extracts the `api_key` already carried on the
  client struct, matching any client that exposes a binary `:api_key` so it
  stays decoupled from `Normandy.LLM`.
  """

  @callback get_token(provider :: term(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  defmodule FromClient do
    @moduledoc "Default CredentialProvider: reads the binary api_key off the client."
    @behaviour Normandy.Behaviours.CredentialProvider

    @impl true
    def get_token(%{api_key: key}, _opts) when is_binary(key), do: {:ok, key}
    def get_token(_provider, _opts), do: {:error, :no_api_key}
  end
end
