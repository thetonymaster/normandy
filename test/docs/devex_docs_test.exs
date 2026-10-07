defmodule Normandy.Docs.DevexDocsTest do
  @moduledoc """
  Devex Tier 3-4 docs fixes (DX-20, DX-32, DX-34, DX-35) stay fixed.
  """
  use ExUnit.Case, async: true

  # Files whose `iex>` examples run as doctests (`doctest` in a test module).
  @doctested [
    "lib/normandy/components/agent_memory.ex",
    "lib/normandy/components/system_prompt_generator.ex",
    "lib/normandy/coordination/pattern.ex",
    "lib/normandy/telemetry/usage.ex",
    "lib/normandy/tools/input.ex",
    "lib/normandy/type.ex"
  ]

  test "DX-32: every iex> example in lib/ is doctested" do
    with_examples =
      for path <- Path.wildcard("lib/**/*.ex"),
          File.read!(path) =~ ~r/^\s*iex>/m,
          do: path

    undoctested = Enum.sort(with_examples -- @doctested)

    assert undoctested == [],
           "expected iex> examples only in doctested files, found them in: " <>
             inspect(undoctested)
  end
end
