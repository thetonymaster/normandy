defmodule Normandy.Behaviours.CredentialProvider do
  @moduledoc """
  Contract for resolving an LLM provider token.

  `Turn.Server` calls `get_token/2` each time it rebuilds a config from a stored template,
  with `%{model: model}` as the provider, and hands the token to the supplement's
  `client_builder`. Nothing else consumes it: a config built with `BaseAgent.init/1` keeps
  its client.

  There is no default implementation: the rebuild has no client to read a key from, so a
  provider returns the credential itself (from the environment, a vault, ...). The
  `credential` slot of `Normandy.Behaviours.Config` is `nil` until set, and
  `Turn.Session.new/1` refuses a session with a `:template_provider` whose config leaves it
  unset.

      defmodule MyApp.EnvCredentials do
        @behaviour Normandy.Behaviours.CredentialProvider

        @impl true
        def get_token(_provider, _opts) do
          case System.fetch_env("ANTHROPIC_API_KEY") do
            {:ok, token} -> {:ok, token}
            :error -> {:error, :no_api_key}
          end
        end
      end
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
end
