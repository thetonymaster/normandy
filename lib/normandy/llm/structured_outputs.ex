defmodule Normandy.LLM.StructuredOutputs do
  @moduledoc """
  Decides whether a request should use Anthropic structured outputs. Enabled
  by default; disable globally via `config :normandy, :structured_outputs,
  false` or per-call via `client.options[:structured_outputs]`. A schema that
  the `SchemaTranslator` cannot express falls back (`:skip`).
  """

  alias Normandy.LLM.Json.SchemaTranslator

  @spec enabled?(struct()) :: boolean()
  def enabled?(client) do
    case Map.get(client.options || %{}, :structured_outputs) do
      nil -> Application.get_env(:normandy, :structured_outputs, true)
      value -> value
    end
  end

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
