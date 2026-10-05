defmodule Normandy.Hooks.GuideExamplesTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Hooks

  @guide Path.expand("../../docs/guides/hooks.md", __DIR__)

  # Compiled once: compiling an example module twice would warn about the redefinition.
  setup_all do
    compiled =
      for source <- example_modules() do
        Code.with_diagnostics(fn -> Code.compile_string(source) end)
      end

    %{compiled: compiled}
  end

  # Every ```elixir block in the guide that defines a MyApp.Hooks.* module.
  defp example_modules do
    ~r/```elixir\n(defmodule MyApp\.Hooks\..*?)```/s
    |> Regex.scan(File.read!(@guide), capture: :all_but_first)
    |> List.flatten()
  end

  # The guide's section under `heading`, up to the next `## ` heading.
  defp section(heading) do
    [_before, rest] = String.split(File.read!(@guide), "\n## #{heading}\n", parts: 2)
    rest |> String.split("\n## ", parts: 2) |> hd()
  end

  test "the guide's example hook modules compile without warnings", %{compiled: compiled} do
    assert length(compiled) == 4

    for {_modules, diagnostics} <- compiled do
      assert diagnostics == [], "example did not compile cleanly: #{inspect(diagnostics)}"
    end
  end

  test "the Events table has a row for every event" do
    events = section("Events")
    for {event, _arity} <- Hooks.events(), do: assert(events =~ "\n| `#{event}(")
  end

  test "the guide's \"Testing a hook\" example passes" do
    [source] =
      Regex.run(
        ~r/```elixir\n(defmodule MyAppTest\.RedactHookTest.*?)```/s,
        section("Testing a hook"),
        capture: :all_but_first
      )

    # The guide's module is run by hand below; registering it with ExUnit after
    # the suite started fails under --trace and --slowest.
    source = String.replace(source, "use ExUnit.Case,", "use ExUnit.Case, register: false,")
    [{module, _binary}] = Code.compile_string(source)
    tests = module.__ex_unit__().tests
    assert length(tests) == 2

    for test <- tests, do: apply(module, test.name, [%{}])
  end
end
