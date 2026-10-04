defmodule Normandy.Hooks.GuideExamplesTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Hooks

  @guide Path.expand("../../docs/guides/hooks.md", __DIR__)

  # Every ```elixir block in the guide that defines a MyApp.Hooks.* module.
  defp example_modules do
    ~r/```elixir\n(defmodule MyApp\.Hooks\..*?)```/s
    |> Regex.scan(File.read!(@guide), capture: :all_but_first)
    |> List.flatten()
  end

  test "the guide's example hook modules compile without warnings" do
    sources = example_modules()
    assert length(sources) == 4

    for source <- sources do
      {_modules, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(source) end)
      assert diagnostics == [], "example did not compile cleanly: #{inspect(diagnostics)}"
    end
  end

  test "the guide's event table names every event" do
    guide = File.read!(@guide)
    for {event, _arity} <- Hooks.events(), do: assert(guide =~ "`#{event}`")
  end
end
