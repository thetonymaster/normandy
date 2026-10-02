defmodule Normandy.Agents.ConverseResult do
  @moduledoc """
  Flattens the `Normandy.Agents.Model.converse/7` return into
  `{:ok, {response, usage, meta}}` or `{:error, %Normandy.LLMError{}}`.

  Implementations may return `struct()`, `{struct(), usage}`, `{struct(), usage, meta}`
  (and, in raw mode, the same shapes with a binary), or `{:error, %Normandy.LLMError{}}`.
  `meta` carries per-call facts that are not token usage, such as `:served_by`. Bare and
  2-tuple returns stay accepted so third-party `Model` implementations keep working; an
  `{:error, term}` that is not an `LLMError` becomes `type: :unknown`. Any other return
  raises `ArgumentError`.
  """

  alias Normandy.Components.ContentBlock.Describe
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

  # Anything else is a Model implementation bug (nil, a plain map, {:ok, struct}).
  # Passing it on as the response failed later, far from the cause.
  def normalize(other) do
    raise ArgumentError,
          "Normandy.Agents.ConverseResult.normalize/1: converse/7 must return a struct or " <>
            "binary response, {response, usage}, {response, usage, meta} or " <>
            "{:error, reason}; got #{describe(other)}"
  end

  defp describe(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
    do: "a {#{inspect(elem(tuple, 0))}, ...} tuple"

  defp describe(other), do: Describe.type_of(other)
end
