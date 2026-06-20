defmodule Normandy.Agents.ConverseResult do
  @moduledoc """
  Flattens the dual-shaped `Normandy.Agents.Model.converse/7` return —
  `struct()` or `{struct(), usage}` (and, in raw mode, `binary()` /
  `{binary(), usage}`) — into a single `{response, usage}` tuple, so callers
  stop assuming one shape. The protocol contract is intentionally left
  dual-shaped for backward compatibility; this is the single place consumers
  normalize it.
  """

  @spec normalize(term()) :: {term(), map() | nil}
  def normalize({response, usage}) when is_struct(response) or is_binary(response),
    do: {response, usage}

  def normalize(response) when is_struct(response) or is_binary(response),
    do: {response, nil}

  def normalize(other), do: {other, nil}
end
