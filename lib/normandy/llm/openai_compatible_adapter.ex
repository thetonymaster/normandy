defmodule Normandy.LLM.OpenAICompatibleAdapter do
  @moduledoc """
  Adapter implementing `Normandy.Agents.Model` against any OpenAI-compatible
  Chat Completions endpoint (OpenAI, DigitalOcean Inference, etc.).

  Text-completion only (v1): tool/function calling is not supported and a
  non-empty `request.tools` raises. Structured output + prose fallback reuse the
  same `Normandy.LLM.JsonDeserializer` path as `Normandy.LLM.ClaudioAdapter`.

      client = %Normandy.LLM.OpenAICompatibleAdapter{
        api_key: System.get_env("OPENAI_API_KEY"),
        base_url: "https://api.openai.com/v1"
      }

  ## Options

  The adapter reads these keys from `options` (a map):

  - `:timeout` - how long to wait for the response, in milliseconds (default: 120_000)
  - `:req_options` - Req options merged into the request (see "Transport injection")
  - `:max_tokens_param` - which body key carries the request's `max_tokens`:
    `:max_tokens` (the default), `:max_completion_tokens` (OpenAI reasoning models), or
    `:omit` (send neither; the server's own limit applies). Any other value raises
    `ArgumentError` when the agent is built (`BaseAgent.init/1`)

  ## Transport injection (testing)

  `options[:req_options]` is merged into the Req request, so tests can route
  the HTTP layer to a `Req.Test` stub without network access (this needs
  `:plug` in your test dependencies):

      Req.Test.stub(MyStub, fn conn ->
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "hi"}}]})
      end)

      client = %Normandy.LLM.OpenAICompatibleAdapter{
        api_key: "test",
        options: %{req_options: [plug: {Req.Test, MyStub}]}
      }

  ## Errors

  `converse/3` returns `{:ok, %Normandy.LLM.Response{}}`, or
  `{:error, %Normandy.LLMError{}}` on non-2xx responses or transport failures,
  classified as follows:

  - 429 → `:rate_limit`, retryable
  - 408, 5xx → `:server`, retryable
  - 401 → `:authentication`, not retryable
  - 403 → `:permission`, not retryable
  - 404 → `:not_found`, not retryable
  - Other 4xx → `:invalid_request`, not retryable
  - Other status → `:unknown`, not retryable
  - `Req.TransportError`, `Mint.TransportError`, `Mint.HTTPError` → `:transport`, retryable
  - Anything else → wrapped via `LLMError.wrap/1`

  `stream/3` returns `{:error, %Normandy.LLMError{type: :unsupported}}`: this adapter
  does not stream.
  """

  use Normandy.Schema

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.LLM.JsonDeserializer
  alias Normandy.LLM.ParseFailure
  alias Normandy.LLM.Request
  alias Normandy.LLMError
  alias Normandy.Telemetry.Request, as: TelemetryRequest

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          options: map(),
          finch: atom() | nil
        }

  @derive {Inspect, except: [:api_key]}
  schema do
    field(:api_key, :string, required: true)
    field(:base_url, :string, default: "https://api.openai.com/v1")
    field(:options, :map, default: %{})
    field(:finch, :any, default: nil)
  end

  # --- Pure helpers (public for tests) ---

  @doc false
  def convert_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %Normandy.Components.Message{role: role, content: content}
      when role in ["system", "user", "assistant"] and is_binary(content) ->
        %{"role" => role, "content" => content}

      %Normandy.Components.Message{role: role, content: content} ->
        raise ArgumentError,
              "OpenAICompatibleAdapter (text-only v1): unsupported message " <>
                "role=#{inspect(role)} / content: " <>
                Describe.type_of(content)
    end)
  end

  @doc false
  def extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
      when is_binary(content),
      do: content

  def extract_text(_), do: ""

  @max_tokens_params [:max_tokens, :max_completion_tokens, :omit]

  @doc """
  Checks `client.options` once, up front; `BaseAgent.init/1` calls it. Raises
  `ArgumentError` for an unknown `:max_tokens_param`.
  """
  @spec validate_options!(t()) :: t()
  def validate_options!(%__MODULE__{options: options} = client) do
    case Map.get(options, :max_tokens_param, :max_tokens) do
      param when param in @max_tokens_params ->
        client

      other ->
        raise ArgumentError,
              "OpenAICompatibleAdapter: :max_tokens_param must be :max_tokens, " <>
                ":max_completion_tokens or :omit, got: #{inspect(other)}"
    end
  end

  @doc false
  def build_body(model, temperature, max_tokens, messages, max_tokens_param \\ :max_tokens) do
    %{"model" => model, "messages" => convert_messages(messages)}
    |> put_unless_nil("temperature", temperature)
    |> put_max_tokens(max_tokens_param, max_tokens)
  end

  defp put_max_tokens(body, :omit, _max_tokens), do: body

  defp put_max_tokens(body, param, max_tokens),
    do: put_unless_nil(body, Atom.to_string(param), max_tokens)

  @doc false
  # The first choice's finish_reason mapped onto Anthropic's stop reasons. A closed
  # mapping: a provider string never becomes an atom. response_meta/1 keeps the raw
  # string as :finish_reason.
  @spec stop_reason(term()) :: Normandy.LLM.Response.stop_reason() | nil
  def stop_reason(%{"choices" => [%{"finish_reason" => reason} | _]}) do
    case reason do
      "stop" -> :end_turn
      "length" -> :max_tokens
      "tool_calls" -> :tool_use
      "content_filter" -> :refusal
      _ -> nil
    end
  end

  def stop_reason(_body), do: nil

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  @doc false
  # Per-call facts that are not token usage: the completion id and the first
  # choice's finish_reason (a string, e.g. "stop"). Keys the body lacks are left out.
  @spec response_meta(term()) :: map()
  def response_meta(%{} = body) do
    finish_reason =
      case Map.get(body, "choices") do
        [%{"finish_reason" => reason} | _] -> reason
        _ -> nil
      end

    [response_id: Map.get(body, "id"), finish_reason: finish_reason]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def response_meta(_body), do: %{}

  @doc false
  # Classifies a non-2xx chat-completions response (spec §2).
  @spec __to_llm_error__(integer(), term()) :: LLMError.t()
  def __to_llm_error__(status, body) when is_integer(status) do
    {type, retryable?} = classify_status(status)

    LLMError.new(
      type: type,
      status: status,
      retryable?: retryable?,
      detail: error_detail(body, status),
      reason: body
    )
  end

  @doc false
  @spec __to_llm_error__(term()) :: LLMError.t()
  def __to_llm_error__(%module{} = e)
      when module in [Req.TransportError, Mint.TransportError, Mint.HTTPError] do
    LLMError.new(type: :transport, retryable?: true, detail: Exception.message(e), reason: e)
  end

  def __to_llm_error__(other), do: LLMError.wrap(other)

  @doc false
  # The [:normandy, :llm, :request] span's outcome for a `Req.post/2` result.
  @spec __request_outcome__(term()) :: {:ok, map()} | {:error, LLMError.t()}
  def __request_outcome__({:ok, %Req.Response{status: status, body: body}})
      when status in 200..299 do
    meta = response_meta(body)
    usage = if is_map(body), do: Map.get(body, "usage")

    {:ok,
     TelemetryRequest.stop_metadata(
       Map.get(meta, :response_id),
       Map.get(meta, :finish_reason),
       usage
     )}
  end

  def __request_outcome__({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, __to_llm_error__(status, body)}

  def __request_outcome__({:error, error}), do: {:error, __to_llm_error__(error)}

  defp classify_status(429), do: {:rate_limit, true}
  defp classify_status(408), do: {:server, true}
  defp classify_status(status) when status in 500..599, do: {:server, true}
  defp classify_status(401), do: {:authentication, false}
  defp classify_status(403), do: {:permission, false}
  defp classify_status(404), do: {:not_found, false}
  defp classify_status(status) when status in 400..499, do: {:invalid_request, false}
  defp classify_status(_status), do: {:unknown, false}

  defp error_detail(%{"error" => %{"message" => message}}, _status) when is_binary(message),
    do: message

  defp error_detail(_body, status), do: "HTTP #{status}"

  defimpl Normandy.Agents.Model do
    alias Normandy.LLM.OpenAICompatibleAdapter, as: A

    def converse(client, %Request{} = request, opts) do
      if request.tools != [] do
        raise ArgumentError,
              "OpenAICompatibleAdapter does not support tools (text-only v1), got " <>
                "#{length(request.tools)} tool schema(s)"
      end

      url = String.trim_trailing(client.base_url, "/") <> "/chat/completions"

      body =
        A.build_body(
          request.model,
          request.temperature,
          request.max_tokens,
          Request.messages_with_system(request),
          Map.get(client.options, :max_tokens_param, :max_tokens)
        )

      req_options =
        [
          json: body,
          headers: [{"authorization", "Bearer " <> client.api_key}],
          receive_timeout: Map.get(client.options, :timeout, 120_000)
        ] ++ Map.get(client.options, :req_options, [])

      result =
        TelemetryRequest.span(
          Keyword.get(opts, :request_tracker),
          Keyword.get(opts, :request_kind),
          %{model: request.model, provider: :openai_compatible, stream: false},
          fn -> Req.post(url, req_options) end,
          &A.__request_outcome__/1
        )

      case result do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          content = A.extract_text(resp_body)

          case populate(content, client, request) do
            {:error, %Normandy.LLMError{} = error} ->
              {:error, Normandy.LLMError.with_usage(error, Map.get(resp_body, "usage"))}

            populated ->
              {:ok,
               %Normandy.LLM.Response{
                 content: populated,
                 stop_reason: A.stop_reason(resp_body),
                 usage: Map.get(resp_body, "usage"),
                 meta: A.response_meta(resp_body)
               }}
          end

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          {:error, A.__to_llm_error__(status, resp_body)}

        {:error, error} ->
          {:error, A.__to_llm_error__(error)}
      end
    end

    def stream(_client, _request, _opts) do
      {:error,
       Normandy.LLMError.new(
         type: :unsupported,
         retryable?: false,
         detail: "OpenAICompatibleAdapter does not stream"
       )}
    end

    # Mirror ClaudioAdapter.convert_response_to_normandy/populate_standard_schema.
    # max_retries: 0 → one-shot parse: if content is valid JSON it populates
    # the schema; if not, :on_parse_failure decides (Normandy.LLM.ParseFailure).
    # No extra LLM round-trips are wasted for prose responses.
    defp populate(content, client, %Request{response_model: %{__struct__: _} = schema} = request) do
      case JsonDeserializer.deserialize_with_retry(content, schema, client, request,
             max_retries: 0
           ) do
        {:ok, validated} -> validated
        {:error, reason} -> ParseFailure.apply(schema, content, reason, %{client: client})
      end
    end

    defp populate(content, _client, _request), do: content
  end
end
