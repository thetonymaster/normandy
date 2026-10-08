defmodule Normandy.Docs.ExamplesReadmeTest do
  @moduledoc """
  DX-29 (decision 27 E1): the 1.x example apps are gone, and `examples/README.md`
  points at the guides; every relative link in it resolves.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @readme Path.join(@root, "examples/README.md")

  test "the 1.x example apps are gone" do
    refute File.exists?(Path.join(@root, "examples/customer_support_app/mix.exs"))
    refute File.exists?(Path.join(@root, "examples/agent_horde/mix.exs"))
    assert File.exists?(Path.join(@root, "examples/tools/weather.ex"))
  end

  test "the README names no removed app and links every guide" do
    text = File.read!(@readme)

    refute text =~ "customer_support_app"
    refute text =~ "CustomerSupport"
    refute text =~ "BaseTool"

    links =
      ~r/\]\(([^)#]+)\)/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&String.starts_with?(&1, "http"))

    for guide <- ~w(distributed_sessions.md agent-memory.md hooks.md testing.md) do
      assert "../docs/guides/#{guide}" in links
    end

    for link <- links do
      assert File.exists?(Path.expand(link, Path.dirname(@readme))),
             "examples/README.md links #{link}, which does not exist"
    end
  end
end
