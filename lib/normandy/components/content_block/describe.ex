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

  # An error or exit reason by its tag only: the atom, a tagged tuple's tag, or an
  # exception's module. Its terms can carry call arguments, response bodies or secrets.
  @spec reason_tag(term()) :: String.t()
  def reason_tag(%mod{__exception__: true}), do: inspect(mod)

  def reason_tag(reason)
      when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
      do: inspect(elem(reason, 0))

  def reason_tag(reason) when is_atom(reason), do: inspect(reason)
  def reason_tag(reason), do: type_of(reason)
end
