defmodule Normandy.JSONTest do
  # The default adapter (Jason): config/test.exs sets no :adapter.
  use ExUnit.Case, async: true

  defmodule Plain do
    @moduledoc false
    defstruct [:a, :nested]
  end

  defmodule Derived do
    @moduledoc false
    @derive {Jason.Encoder, only: [:shown]}
    defstruct [:shown, :hidden]
  end

  defmodule WithMeta do
    @moduledoc false
    use Normandy.Schema

    schema do
      field(:name, :string)
    end
  end

  describe "encode!/2" do
    test "a struct without an encoder is encoded as its map, at any depth" do
      json = Normandy.JSON.encode!(%{list: [%Plain{a: 1, nested: %Plain{a: 2}}]})

      assert Jason.decode!(json) == %{
               "list" => [%{"a" => 1, "nested" => %{"a" => 2, "nested" => nil}}]
             }
    end

    test "a struct's :__meta__ is left out" do
      assert Jason.decode!(Normandy.JSON.encode!(%WithMeta{name: "x"})) == %{"name" => "x"}
    end

    test "a struct with its own encoder is encoded by it" do
      assert Normandy.JSON.encode!(%Derived{shown: "a", hidden: "b"}) == ~s({"shown":"a"})
      assert Normandy.JSON.encode!(%{on: ~D[2026-10-05]}) == ~s({"on":"2026-10-05"})
    end

    test "pretty: true reaches the adapter" do
      assert Normandy.JSON.encode!(%{a: 1}, pretty: true) == "{\n  \"a\": 1\n}"
    end

    test "a term JSON cannot express raises the adapter's exception" do
      assert_raise Protocol.UndefinedError, fn -> Normandy.JSON.encode!(%{a: {1, 2}}) end
    end
  end

  describe "encode/2" do
    test "returns the JSON" do
      assert {:ok, ~s({"a":{"a":1,"nested":null}})} = Normandy.JSON.encode(%{a: %Plain{a: 1}})
    end

    test "returns the adapter's exception for a term JSON cannot express" do
      assert {:error, %Protocol.UndefinedError{value: {1, 2}}} =
               Normandy.JSON.encode(%{a: {1, 2}})
    end
  end

  describe "decode/1 and decode!/1" do
    test "an object decodes to a string-keyed map" do
      assert {:ok, %{"a" => [1, %{"b" => nil}]}} = Normandy.JSON.decode(~s({"a":[1,{"b":null}]}))
      assert Normandy.JSON.decode!(~s({"a":1})) == %{"a" => 1}
    end

    test "text that is not JSON is the adapter's exception" do
      assert {:error, %Jason.DecodeError{}} = Normandy.JSON.decode("not json")
      assert_raise Jason.DecodeError, fn -> Normandy.JSON.decode!("not json") end
    end
  end
end
