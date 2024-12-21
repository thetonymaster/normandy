defmodule Normandy.TypeTest do
  use ExUnit.Case, async: true

  defmodule Custom do
    use Normandy.Tools.Type
    def type, do: :custom
    def dump(_), do: {:ok, :dump}
    def cast(_), do: {:ok, :cast}
    def equal?(true, _), do: true
    def equal?(_, _), do: false
    def embed_as(_), do: :dump
  end

  defmodule CustomAny do
    use Normandy.Tools.Type
    def type, do: :any
    def dump(_), do: {:ok, :dump}
    def cast(_), do: {:ok, :cast}
  end

  defmodule CustomWithCastError do
    use Normandy.Tools.Type

    def type, do: :any
    def dump(_), do: {:ok, :dump}
    def cast("a"), do: {:ok, "a"}
    def cast("b"), do: {:error, foo: :bar, value: "b"}
    def cast("c"), do: {:error, foo: :bar, source: [:email], value: "c"}
    def cast("d"), do: {:error, message: "custom message"}
  end

  defmodule CustomParameterizedTypeWithFormat do
    use Normandy.Tools.ParameterizedType

    def init(_options), do: :init
    def type(_), do: :custom
    def dump(_, _, _), do: {:ok, :dump}
    def cast(_, _), do: {:ok, :cast}
    def equal?(true, _, _), do: true
    def equal?(_, _, _), do: false
    def format(_params), do: "#CustomParameterizedTypeWithFormat<:custom>"
  end

  defmodule CustomParameterizedTypeWithoutFormat do
    use Normandy.Tools.ParameterizedType

    def init(_options), do: :init
    def type(_), do: :custom
    def dump(_, _, _), do: {:ok, :dump}
    def cast(_, _), do: {:ok, :cast}
    def equal?(true, _, _), do: true
    def equal?(_, _, _), do: false
  end

  defmodule Schema do
    use Normandy.Tools.Schema

    schema do
      field :a, :integer, source: :abc
      field :b, :integer, virtual: true
      field :c, :integer, default: 0
    end
  end

  import Kernel, except: [match?: 2], warn: false
  import Normandy.Tools.Type
  doctest Normandy.Tools.Type

    test "embed_as" do
    assert embed_as(:string, :json) == :self
    assert embed_as(:integer, :json) == :self
    assert embed_as(Custom, :json) == :dump
    assert embed_as(CustomAny, :json) == :self
  end
end
