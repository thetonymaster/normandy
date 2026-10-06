defmodule Normandy.JSON do
  @moduledoc """
  The one place Normandy encodes and decodes JSON.

  ## Adapter

  The JSON library is `config :normandy, adapter: Module`, read on every call (so
  runtime config applies), default `Jason`. Normandy calls exactly two of its
  functions, so any module that provides them works:

    * `encode!(term, opts) :: String.t()` — raises on a term it cannot encode.
      `opts` is `[]` or `[pretty: true]`.
    * `decode(String.t()) :: {:ok, term()} | {:error, Exception.t()}` — objects
      decode to string-keyed maps.

  ## Structs

  Before the adapter sees a term, every struct in it, at any depth, is either kept
  or replaced by a plain map:

    * A struct with its own `Jason.Encoder` implementation (`@derive Jason.Encoder`,
      a `defimpl`, or one Jason ships: `Date`, `DateTime`, `Decimal`, ...) is kept,
      and that implementation decides its fields. Its fields are not walked.
    * Any other struct becomes its map without `:__struct__` and `:__meta__`, and
      its values are walked the same way.

  The check is `Jason.Encoder` whatever the adapter, because Jason is always a
  Normandy dependency. With another adapter, a derived struct reaches that adapter
  as a struct and the adapter decides how to encode it.

  A term JSON cannot express (a tuple, a pid, a reference, a function) is left as
  it is: the adapter raises on it, and `encode/2` returns that exception.
  """

  alias Normandy.Components.ContentBlock.Describe

  @doc "Encodes `term`; raises the adapter's exception when it cannot."
  @spec encode!(term(), keyword()) :: String.t()
  def encode!(term, opts \\ []) when is_list(opts) do
    adapter().encode!(normalize(term), opts)
  end

  @doc """
  Encodes `term`, returning `{:error, exception}` with whatever the adapter raised
  (for Jason, `Protocol.UndefinedError` or `Jason.EncodeError`), or what walking `term`
  raised (an improper list). A misconfigured `:adapter` raises.
  """
  @spec encode(term(), keyword()) :: {:ok, String.t()} | {:error, Exception.t()}
  def encode(term, opts \\ []) when is_list(opts) do
    adapter = adapter()

    try do
      {:ok, adapter.encode!(normalize(term), opts)}
    rescue
      exception -> {:error, exception}
    end
  end

  @doc "Decodes a JSON string; objects become string-keyed maps."
  @spec decode(String.t()) :: {:ok, term()} | {:error, Exception.t()}
  def decode(json) when is_binary(json) do
    adapter = adapter()

    case adapter.decode(json) do
      {:ok, _value} = ok ->
        ok

      {:error, %{__exception__: true}} = error ->
        error

      other ->
        raise ArgumentError,
              "#{inspect(adapter)}.decode/1 must return {:ok, term} or {:error, exception}, " <>
                "got: #{shape(other)}"
    end
  end

  @doc "Decodes a JSON string; raises the adapter's exception when it is not JSON."
  @spec decode!(String.t()) :: term()
  def decode!(json) when is_binary(json) do
    case decode(json) do
      {:ok, value} -> value
      {:error, exception} -> raise exception
    end
  end

  defp adapter do
    case Application.get_env(:normandy, :adapter, Jason) do
      module when is_atom(module) and not is_nil(module) ->
        module

      other ->
        raise ArgumentError,
              "config :normandy, :adapter must be a module with encode!/2 and decode/1, " <>
                "got: #{Describe.type_of(other)}"
    end
  end

  defp shape({:error, _reason}), do: "{:error, a reason that is not an exception}"
  defp shape(other), do: Describe.type_of(other)

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
  # Shared with Normandy.Schema.__serializable__/1, which applies the same rule.
  @spec own_encoder?(struct()) :: boolean()
  def own_encoder?(struct), do: Jason.Encoder.impl_for(struct) not in [nil, Jason.Encoder.Any]
end
