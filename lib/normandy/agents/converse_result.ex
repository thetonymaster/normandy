defmodule Normandy.Agents.ConverseResult do
  @moduledoc """
  Flattens the `Normandy.Agents.Model.converse/7` return into a single
  `{response, usage, meta}` triple, so callers stop assuming one shape.

  Implementations may return `struct()`, `{struct(), usage}` or
  `{struct(), usage, meta}` (and, in raw mode, the same shapes with a binary).
  `meta` carries per-call facts that are not token usage, such as `:served_by`
  (the model that produced the message after a server-side fallback). Bare and
  2-tuple returns stay accepted so third-party `Model` implementations keep working.
  """

  @spec normalize(term()) :: {term(), map() | nil, map()}
  def normalize({response, usage, meta})
      when (is_struct(response) or is_binary(response)) and is_map(meta),
      do: {response, usage, meta}

  def normalize({response, _usage, meta}) when is_struct(response) or is_binary(response) do
    raise ArgumentError,
          "Normandy.Agents.ConverseResult.normalize/1: a {response, usage, meta} return " <>
            "needs a map as meta, got: #{inspect(meta)}. Return %{} when there is no meta."
  end

  def normalize({response, usage}) when is_struct(response) or is_binary(response),
    do: {response, usage, %{}}

  def normalize(response) when is_struct(response) or is_binary(response),
    do: {response, nil, %{}}

  def normalize(other), do: {other, nil, %{}}
end
