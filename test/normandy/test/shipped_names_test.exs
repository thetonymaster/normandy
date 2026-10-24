defmodule Normandy.Test.ShippedNamesTest do
  @moduledoc """
  Decision 27 D1: `lib/` ships `Normandy.Test.*` modules, and `test/support` (compiled into
  the same app in the test env) never defines a module name `lib/` ships. Reads the
  sources: when both define a name, only one module survives compilation.
  """
  use ExUnit.Case, async: true

  defp defined_modules(glob) do
    glob
    |> Path.wildcard()
    |> Enum.flat_map(fn path -> path |> File.read!() |> Code.string_to_quoted!() |> walk([]) end)
    |> MapSet.new()
  end

  # Every `defmodule` name, nested ones under their parent's name.
  defp walk({:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}, prefix) do
    name = prefix ++ parts
    [Module.concat(name) | walk(body, name)]
  end

  defp walk({left, _meta, args}, prefix) when is_list(args),
    do: walk(left, prefix) ++ Enum.flat_map(args, &walk(&1, prefix))

  defp walk({left, right}, prefix), do: walk(left, prefix) ++ walk(right, prefix)
  defp walk(list, prefix) when is_list(list), do: Enum.flat_map(list, &walk(&1, prefix))
  defp walk(_other, _prefix), do: []

  test "test/support defines no module that lib/ ships" do
    shipped = defined_modules("lib/**/*.ex")
    support = defined_modules("test/support/**/*.ex")

    # The walk finds both sides' modules, nested ones included.
    assert Normandy.Test.FakeClient in shipped
    assert Normandy.Test.FakeClient.ScriptExhaustedError in shipped
    assert Normandy.Test.StubClient in support

    assert MapSet.intersection(shipped, support) == MapSet.new()
  end
end
