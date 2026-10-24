defmodule Normandy.JSON do
  @moduledoc """
  The one place Normandy encodes and decodes JSON.

  ## Library

  Normandy encodes and decodes with Jason, which is a hard dependency. There is no
  `:adapter` setting. `decode/1` returns string-keyed maps for objects.

  ## Structs

  Before Jason sees a term, every struct in it, at any depth, is either kept
  or replaced by a plain map:

    * A struct with its own `Jason.Encoder` implementation (`@derive Jason.Encoder`,
      a `defimpl`, or one Jason ships: `Date`, `DateTime`, `Decimal`, ...) is kept,
      and that implementation decides its fields. Its fields are not walked.
    * Any other struct becomes its map without `:__struct__` and `:__meta__` (an Ecto
      schema's, whose encoder raises), and its values are walked the same way.

  A term JSON cannot express (a tuple, a pid, a reference, a function) is left as
  it is: Jason raises on it, and `encode/2` returns that exception.

  ## Text for the model

  The JSON text Normandy writes into a message for the model (a tool result's text,
  a map given as message content) lists every plain map's keys sorted by their text,
  at any depth, so the same value is the same text on every node and after a restart
  (on OTP 26+ a small atom-keyed map iterates its keys in atom-creation order). Values
  and list order are unchanged. A struct without its own `Jason.Encoder` is written as
  its fields, sorted like a plain map. A struct with its own encoder is encoded by that
  encoder, whose output is its own, and a `Jason.OrderedObject` keeps its order (the
  plain maps among its values are sorted).
  """

  @doc "Encodes `term`; raises Jason's exception when it cannot."
  @spec encode!(term(), keyword()) :: String.t()
  def encode!(term, opts \\ []) when is_list(opts) do
    Jason.encode!(normalize(term), opts)
  end

  @doc """
  Encodes `term`, returning `{:error, exception}` with whatever Jason raised
  (`Protocol.UndefinedError` or `Jason.EncodeError`), or what walking `term`
  raised (an improper list).
  """
  @spec encode(term(), keyword()) :: {:ok, String.t()} | {:error, Exception.t()}
  def encode(term, opts \\ []) when is_list(opts) do
    {:ok, Jason.encode!(normalize(term), opts)}
  rescue
    exception -> {:error, exception}
  end

  @doc "Decodes a JSON string; objects become string-keyed maps."
  @spec decode(String.t()) :: {:ok, term()} | {:error, Exception.t()}
  def decode(json) when is_binary(json), do: Jason.decode(json)

  @doc "Decodes a JSON string; raises Jason's exception when it is not JSON."
  @spec decode!(String.t()) :: term()
  def decode!(json) when is_binary(json) do
    case decode(json) do
      {:ok, value} -> value
      {:error, exception} -> raise exception
    end
  end

  defp normalize(%_{} = struct) do
    if own_encoder?(struct) do
      struct
    else
      struct |> Map.from_struct() |> Map.delete(:__meta__) |> normalize()
    end
  end

  defp normalize(map) when is_map(map), do: :maps.map(fn _key, value -> normalize(value) end, map)
  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  @doc false
  # "Text for the model" in the moduledoc: every plain map becomes a Jason.OrderedObject
  # with its keys sorted by their JSON text (ties, such as "a" and :a, by term order, so
  # the result never depends on the map's iteration order). A struct is normalized as
  # encode!/2 does it (a struct with its own encoder is kept whole, unsorted; one without
  # becomes its field map, sorted like any plain map); an OrderedObject keeps its order and
  # its values are walked. Callers: ToolResult.render_output/1 and BaseIOSchema's Map impl.
  @spec sort_keys(term()) :: term()
  def sort_keys(%Jason.OrderedObject{values: values} = object),
    do: %{object | values: Enum.map(values, fn {key, value} -> {key, sort_keys(value)} end)}

  def sort_keys(%_{} = struct) do
    if own_encoder?(struct) do
      struct
    else
      struct |> Map.from_struct() |> Map.delete(:__meta__) |> sort_keys()
    end
  end

  def sort_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, sort_keys(value)} end)
    |> Enum.sort_by(fn {key, _value} -> {key_text(key), key} end)
    |> Jason.OrderedObject.new()
  end

  def sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  def sort_keys(other), do: other

  # A key as Jason writes it: an atom by its name, anything else through String.Chars. A key
  # without a String.Chars impl (a tuple) raises Protocol.UndefinedError here, the exception
  # Jason raised for it before.
  defp key_text(key) when is_atom(key), do: Atom.to_string(key)
  defp key_text(key), do: to_string(key)

  @doc false
  # Shared with Normandy.Schema.__serializable__/1, which applies the same rule.
  @spec own_encoder?(struct()) :: boolean()
  def own_encoder?(struct), do: Jason.Encoder.impl_for(struct) not in [nil, Jason.Encoder.Any]
end
