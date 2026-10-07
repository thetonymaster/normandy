defmodule Normandy.LLM.StructuredOutputs do
  @moduledoc """
  Decides whether a request should use Anthropic structured outputs. Enabled
  by default; disable globally via `config :normandy, :structured_outputs,
  false` or per-call via `client.options[:structured_outputs]`. A schema that
  the `SchemaTranslator` cannot express falls back (`:skip`).
  """

  alias Normandy.LLM.Json.SchemaTranslator

  @doc """
  Returns whether `client` uses structured outputs.

  The client's `options[:structured_outputs]` (map or keyword list) wins when it is not
  `nil`; otherwise `config :normandy, :structured_outputs` decides, `true` by default.
  """
  @spec enabled?(struct()) :: boolean()
  def enabled?(client) do
    opts = client.options || %{}

    override =
      cond do
        is_map(opts) -> Map.get(opts, :structured_outputs)
        is_list(opts) -> Keyword.get(opts, :structured_outputs)
        true -> nil
      end

    case override do
      nil -> Application.get_env(:normandy, :structured_outputs, true)
      value -> value
    end
  end

  @doc """
  Returns `{:ok, schema}`, the translated JSON Schema of `response_model`, or `:skip`.

  `:skip` when structured outputs are off for `client`, when `response_model` is not a struct
  of a module with `get_json_schema/0`, or when `SchemaTranslator` cannot express its
  specification. The caller then uses the legacy parse-and-retry path.
  """
  @spec schema_for(struct(), term()) :: {:ok, map()} | :skip
  def schema_for(client, response_model) do
    with true <- enabled?(client),
         true <- is_struct(response_model),
         true <- function_exported?(response_model.__struct__, :get_json_schema, 0),
         spec <- response_model.__struct__.get_json_schema(),
         {:ok, schema} <- SchemaTranslator.translate(spec) do
      {:ok, schema}
    else
      _ -> :skip
    end
  end
end
