defmodule Normandy.TypeBaseTypesTest do
  use ExUnit.Case, async: true

  alias Normandy.Type

  @samples [
    integer: 1,
    float: 1.5,
    boolean: true,
    string: "s",
    bitstring: <<1::3>>,
    map: %{a: 1},
    binary: "b",
    any: {:anything},
    date: ~D[2026-01-01],
    time: ~T[10:00:00],
    duration: Duration.new!(hour: 1),
    struct: %URI{host: "example.com"}
  ]

  for {type, sample} <- @samples do
    test "#{type}: cast, dump and load each return the value" do
      value = unquote(Macro.escape(sample))
      type = unquote(type)

      assert Type.cast(type, value) == {:ok, value}
      assert Type.dump(type, value) == {:ok, value}
      assert Type.load(type, value) == {:ok, value}
    end
  end

  test "each sampled type is a declared base type" do
    assert Enum.all?(Keyword.keys(@samples), &Type.primitive?/1)
  end
end
