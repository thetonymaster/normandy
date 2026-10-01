defmodule Normandy.Components.ContentBlock.Describe do
  @moduledoc false
  # Error messages name a value's type, never its contents: a content block can
  # hold megabytes of user data, and options can hold credentials.

  @spec type_of(term()) :: String.t()
  def type_of(%mod{}), do: "a %#{inspect(mod)}{}"
  def type_of(value) when is_map(value), do: "a map"
  def type_of(value) when is_list(value), do: "a list"
  def type_of(value) when is_binary(value), do: "a string (#{byte_size(value)} bytes)"
  def type_of(value) when is_atom(value), do: inspect(value)
  def type_of(value) when is_integer(value), do: "an integer"
  def type_of(value) when is_float(value), do: "a float"
  def type_of(value) when is_tuple(value), do: "a tuple"
  def type_of(_value), do: "an unsupported term"
end
