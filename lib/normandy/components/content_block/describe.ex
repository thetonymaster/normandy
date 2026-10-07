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

  # An error reason reduced to a term that is safe to hand back to a caller: atoms and
  # integers are kept, tuples are walked (so {:exit, :noproc} and {:store_exit, {:timeout,
  # {GenServer, :call, 3}}} stay whole), an exception becomes its module (a
  # Postgrex.Error with a SQLSTATE becomes {Postgrex.Error, code}), and any other term
  # (a string, a map, a list, a pid) becomes type_of/1's description of it. A provider's
  # or a store's reason can carry a response body, a query or a secret; its shape and
  # tags are what a caller can act on.
  @spec reason_term(term()) :: term()
  def reason_term(%{__struct__: Postgrex.Error, __exception__: true, postgres: %{code: code}})
      when is_atom(code) and code != nil,
      do: {Postgrex.Error, code}

  def reason_term(%mod{__exception__: true}), do: mod
  def reason_term(reason) when is_atom(reason) or is_integer(reason), do: reason

  def reason_term(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map(&reason_term/1) |> List.to_tuple()

  def reason_term(reason), do: type_of(reason)
end
