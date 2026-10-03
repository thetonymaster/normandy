defmodule Normandy.Telemetry.Provider do
  @moduledoc """
  Names the LLM provider behind a client and the facts about a request that
  telemetry reports on the `[:normandy, :agent, :llm_call]` span.

  `provider/1` is the single place the provider is resolved; other spans reuse it.

  | client                                  | provider              |
  |-----------------------------------------|-----------------------|
  | `Normandy.LLM.ClaudioAdapter`           | `:anthropic`          |
  | `Normandy.LLM.OpenAICompatibleAdapter`  | `:openai_compatible`  |
  | any other struct                        | `client.options[:provider]` when it is an atom, else `nil` |

  `Normandy.Agents.Model` is implemented by third parties, so no function is
  added to it: a custom client names its provider with `options: %{provider: :my_provider}`.
  `nil` means "unknown" and callers leave the key out of the metadata.

  ## llm_call stop metadata (set by the adapters and BaseAgent)

    * `:response_id` - the provider's message/completion id
    * `:finish_reason` - the provider's stop reason as provided: an atom from
      the Claudio non-streaming adapter (`:end_turn`), a string from streaming
      (`"end_turn"`) and from the OpenAI-compatible adapter (`"stop"`)
    * `:time_to_first_chunk` - streaming only; native time units (convert with
      `System.convert_time_unit/3`) from the start of the stream attempt to the
      first text or thinking delta. Absent when the stream had no such delta.
      It is metadata, not a measurement, because `:telemetry.span/3` fixes the
      stop measurements.
  """

  alias Normandy.LLM.{ClaudioAdapter, OpenAICompatibleAdapter}

  @doc "The provider atom for `client`, or `nil` when it cannot be told."
  @spec provider(term()) :: atom() | nil
  def provider(%ClaudioAdapter{}), do: :anthropic
  def provider(%OpenAICompatibleAdapter{}), do: :openai_compatible

  def provider(%{options: %{provider: provider}}) when is_atom(provider) and provider != nil,
    do: provider

  def provider(_client), do: nil

  @doc """
  The host of the client's base URL, or `nil` when none is configured
  (the Claudio adapter then talks to its library default and the host is not known here).
  """
  @spec server_address(term()) :: String.t() | nil
  def server_address(%{} = client) do
    options = Map.get(client, :options)
    options = if is_map(options), do: options, else: %{}

    url = Map.get(client, :base_url) || Map.get(options, :base_url)

    with true <- is_binary(url),
         %URI{host: host} when is_binary(host) and host != "" <- URI.parse(url) do
      host
    else
      _ -> nil
    end
  end

  def server_address(_client), do: nil

  @doc """
  Request facts for the llm_call start metadata. Keys with no value are left out:
  `provider`, `max_tokens`, `temperature` (non-nil only), `effort`, `server_address`.
  `stream` and `structured_output` are always present.

  Options: `:stream` (boolean), `:response_model` (the call's response schema
  struct), `:tools?` (whether the call carries tools).

  `structured_output` is whether native structured outputs are requested for this
  call: true only for a Claudio client, a non-streaming call, no tools, and a
  response schema the translator can express.
  """
  @spec request_metadata(struct(), keyword()) :: map()
  def request_metadata(config, opts) do
    client = config.client
    stream? = Keyword.get(opts, :stream, false)

    options = Map.get(client, :options)
    options = if is_map(options), do: options, else: %{}

    %{
      provider: provider(client),
      stream: stream?,
      max_tokens: config.max_tokens,
      temperature: config.temperature,
      effort: Map.get(options, :effort),
      structured_output: structured_output?(config, opts),
      server_address: server_address(client)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp structured_output?(config, opts) do
    not Keyword.get(opts, :stream, false) and
      match?(%ClaudioAdapter{}, config.client) and
      ClaudioAdapter.__structured_schema_for__(
        config.client,
        Keyword.get(opts, :response_model),
        tools: if(Keyword.get(opts, :tools?, false), do: [:tools], else: [])
      ) != :skip
  end
end
