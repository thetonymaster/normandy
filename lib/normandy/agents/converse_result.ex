defmodule Normandy.Agents.ConverseResult do
  @moduledoc """
  Flattens the `Normandy.Agents.Model.converse/7` return into
  `{:ok, {response, usage, meta}}` or `{:error, %Normandy.LLMError{}}`.

  Implementations may return `struct()`, `{struct(), usage}`, `{struct(), usage, meta}`
  (and, in raw mode, the same shapes with a binary), or `{:error, %Normandy.LLMError{}}`.
  `meta` carries per-call facts that are not token usage, such as `:served_by`. Bare and
  2-tuple returns stay accepted so third-party `Model` implementations keep working; an
  `{:error, term}` that is not an `LLMError` becomes `type: :unknown`.
  """

  alias Normandy.LLMError

  @spec normalize(term()) :: {:ok, {term(), map() | nil, map()}} | {:error, LLMError.t()}
  def normalize({:error, reason}), do: {:error, LLMError.wrap(reason)}

  def normalize({response, usage, meta})
      when (is_struct(response) or is_binary(response)) and is_map(meta),
      do: {:ok, {response, usage, meta}}

  def normalize({response, _usage, meta}) when is_struct(response) or is_binary(response) do
    raise ArgumentError,
          "Normandy.Agents.ConverseResult.normalize/1: a {response, usage, meta} return " <>
            "needs a map as meta, got: #{inspect(meta)}. Return %{} when there is no meta."
  end

  def normalize({response, usage}) when is_struct(response) or is_binary(response),
    do: {:ok, {response, usage, %{}}}

  def normalize(response) when is_struct(response) or is_binary(response),
    do: {:ok, {response, nil, %{}}}

  def normalize(other), do: {:ok, {other, nil, %{}}}
end
