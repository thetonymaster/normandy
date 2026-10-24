defmodule Normandy.Test do
  @moduledoc false

  @doc """
  Returns `value` unchanged, hidden from the compile-time type checker.

  Elixir 1.20 warns when a literal or a value of known type is passed to a
  function that can never accept it. A test that passes a deliberately wrong
  argument (to prove the function raises) wraps it here; the round trip
  through the external term format defeats type inference, so the test keeps
  exercising the wrong input without the warning.
  """
  @spec opaque(term()) :: term()
  def opaque(value), do: value |> :erlang.term_to_binary() |> :erlang.binary_to_term()
end
