defmodule Normandy.Behaviours.CredentialProvider do
  @moduledoc """
  Contract for resolving an LLM provider token.

  `Turn.Server` calls `get_token/2` each time it rebuilds a config from a stored template,
  with `%{model: model}` as the provider, and hands the token to the supplement's
  `client_builder`. Nothing else consumes it: a config built with `BaseAgent.init/1` keeps
  its client.

  The default impl `FromClient` reads a binary `:api_key` off the struct it is given. The
  rebuild passes no client, so `FromClient` returns `{:error, :no_api_key}` there: a session
  rebuilt from a template needs a provider that returns the credential itself.
  """

  @doc """
  Returns `{:ok, token}`, the provider token as a string, or `{:error, reason}`.

  `Turn.Server` calls it when it rebuilds a session's config from its stored template, with
  `%{model: model}` as `provider` and the `opts` of the template's credential ref; the token
  goes to the supplement's `client_builder`. An `{:error, reason}` makes the server wait
  `:unavailable` and retry; the reason is reduced to its tags before it is replied or
  logged.
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
