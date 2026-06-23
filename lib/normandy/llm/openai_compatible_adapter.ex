defmodule Normandy.LLM.OpenAICompatibleAdapter do
  @moduledoc """
  Adapter implementing `Normandy.Agents.Model` against any OpenAI-compatible
  Chat Completions endpoint (OpenAI, DigitalOcean Inference, etc.).

  Text-completion only (v1): tool/function calling is not supported and a
  non-empty `opts[:tools]` raises. Structured output + prose fallback reuse the
  same `Normandy.LLM.JsonDeserializer` path as `Normandy.LLM.ClaudioAdapter`.

      client = %Normandy.LLM.OpenAICompatibleAdapter{
        api_key: System.get_env("OPENAI_API_KEY"),
        base_url: "https://api.openai.com/v1"
      }

  ## Transport injection (testing)

  Pass a custom Req `:adapter` function via `options[:req_options]` to stub the
  HTTP layer in tests without network access:

      adapter_fn = fn request ->
        response = Req.Response.json(%{"choices" => [%{"message" => %{"content" => "hi"}}]})
        {request, response}
      end

      client = %Normandy.LLM.OpenAICompatibleAdapter{
        api_key: "test",
        options: %{req_options: [adapter: adapter_fn]}
      }
  """
  use Normandy.Schema

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
                "role=#{inspect(role)} / content=#{inspect(content)}"
    end)
  end

  @doc false
  def extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
      when is_binary(content),
      do: content

  def extract_text(_), do: ""

  @doc false
  def build_body(model, temperature, max_tokens, messages) do
    %{
      "model" => model,
      "messages" => convert_messages(messages),
      "temperature" => temperature,
      "max_tokens" => max_tokens
    }
  end

  defimpl Normandy.Agents.Model do
    alias Normandy.LLM.OpenAICompatibleAdapter, as: A

    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(client, model, temperature, max_tokens, messages, response_model, opts \\ []) do
      if Keyword.get(opts, :tools, []) != [] do
        raise ArgumentError,
              "OpenAICompatibleAdapter does not support tools (text-only v1)"
      end

      url = String.trim_trailing(client.base_url, "/") <> "/chat/completions"
      body = A.build_body(model, temperature, max_tokens, messages)

      req_options =
        [
          json: body,
          headers: [{"authorization", "Bearer " <> client.api_key}],
          receive_timeout: Map.get(client.options, :timeout, 120_000)
        ] ++ Map.get(client.options, :req_options, [])

      case Req.post(url, req_options) do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          content = A.extract_text(resp_body)

          populated =
            populate(content, response_model, client, model, temperature, max_tokens, messages)

          {populated, Map.get(resp_body, "usage")}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          IO.warn("OpenAI-compatible API error #{status}: #{inspect(resp_body)}")
          {response_model, nil}

        {:error, error} ->
          IO.warn("OpenAI-compatible transport error: #{inspect(error)}")
          {response_model, nil}
      end
    end

    # Mirror ClaudioAdapter.convert_response_to_normandy/populate_standard_schema.
    # max_retries: 0 → one-shot parse: if content is valid JSON it populates
    # the schema; if not, the prose fallback sets :chat_message directly.
    # No extra LLM round-trips are wasted for prose responses.
    defp populate(
           content,
           %{__struct__: _} = schema,
           client,
           model,
           temperature,
           max_tokens,
           messages
         ) do
      case Normandy.LLM.JsonDeserializer.deserialize_with_retry(
             content,
             schema,
             client,
             model,
             temperature,
             max_tokens,
             messages,
             max_retries: 0
           ) do
        {:ok, validated} -> validated
        {:error, _} when is_binary(content) -> Map.put(schema, :chat_message, content)
        {:error, _} -> schema
      end
    end

    defp populate(content, _non_struct, _c, _m, _t, _mt, _msgs), do: content
  end
end
