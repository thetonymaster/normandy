defmodule Normandy.Behaviours.SessionStore.CodecTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore.Codec

  # External term format for an atom (SMALL_ATOM_UTF8_EXT), built from a string so
  # the test never creates the atom itself.
  defp atom_blob(name), do: <<131, 119, byte_size(name), name::binary>>

  test "round-trips a term" do
    term = %{a: [1, "two", {:three}]}
    assert term |> Codec.encode() |> Codec.decode() == term
  end

  test "decodes an atom from a module that exists but is not loaded yet" do
    name = "Elixir.Normandy.Test.LazyLoaded"
    assert Atom.to_string(Codec.decode(atom_blob(name))) == name
  end

  test "an atom that no code defines still fails to decode" do
    assert_raise ArgumentError, fn ->
      Codec.decode(atom_blob("Elixir.Normandy.Test.NoSuchModule#{System.unique_integer()}"))
    end
  end
end
