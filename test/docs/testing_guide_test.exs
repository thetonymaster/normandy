defmodule Normandy.Docs.TestingGuideTest do
  @moduledoc """
  Task 7.3e: every example in `docs/guides/testing.md` compiles cleanly and every example
  test passes against the shipped `Normandy.Test.*` modules. The counts pin the guide: a
  dropped or broken block fails here.
  """
  use ExUnit.Case, async: true

  @guide Path.expand("../../docs/guides/testing.md", __DIR__)

  # Example test modules, by name, with how many tests each defines.
  @example_tests %{
    "MyAppTest.GreeterTest" => 2,
    "MyAppTest.WeatherAgentTest" => 2,
    "MyAppTest.VerdictTest" => 3,
    "MyAppTest.StreamingTest" => 1,
    "MyAppTest.SessionTest" => 1,
    "MyAppTest.UsageTest" => 1
  }

  # Compiled once: compiling an example module twice would warn about the redefinition.
  setup_all do
    compiled =
      for source <- blocks(~r/```elixir\n(defmodule MyApp\..*?)```/s) do
        Code.with_diagnostics(fn -> Code.compile_string(source) end)
      end

    %{compiled: compiled}
  end

  defp blocks(regex) do
    regex
    |> Regex.scan(File.read!(@guide), capture: :all_but_first)
    |> List.flatten()
  end

  # The guide's test module named `name`, compiled unregistered: ExUnit's own run has
  # started, and registering a module now fails under --trace and --slowest.
  defp example_test_module(name, swaps \\ []) do
    [source] = blocks(~r/```elixir\n(defmodule #{Regex.escape(name)} do.*?)```/s)

    source =
      Enum.reduce([{"use ExUnit.Case,", "use ExUnit.Case, register: false,"} | swaps], source, fn
        {from, to}, source ->
          assert source =~ from, "#{name}: the guide's example no longer contains #{from}"
          String.replace(source, from, to)
      end)

    {[{module, _binary}], diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(source) end)

    assert diagnostics == [], "#{name} did not compile cleanly: #{inspect(diagnostics)}"
    module
  end

  test "the guide's example modules compile without warnings", %{compiled: compiled} do
    assert length(compiled) == 2

    for {_modules, diagnostics} <- compiled do
      assert diagnostics == [], "example did not compile cleanly: #{inspect(diagnostics)}"
    end
  end

  test "the guide has exactly the example test modules listed here" do
    names = blocks(~r/```elixir\ndefmodule (MyAppTest\.\w+) do/)

    assert Enum.sort(names) ==
             Enum.sort(Map.keys(@example_tests) ++ ["MyAppTest.SessionStoreTest"])
  end

  for {name, count} <- @example_tests do
    test "the guide's #{name} passes" do
      module = example_test_module(unquote(name))
      tests = module.__ex_unit__().tests
      assert length(tests) == unquote(count)

      for test <- tests do
        context = module.__ex_unit__(:setup, %{test: test.name, module: module})
        apply(module, test.name, [context])
      end
    end
  end

  defmodule ContractReference do
    use ExUnit.Case, register: false
    use Normandy.Test.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.InMemory
  end

  test "the guide's store contract example defines the whole contract" do
    # The guide's MyApp.SessionStore is played by InMemory. Running the tests would
    # repeat the InMemory contract run; the count shows the guide's options were
    # accepted and every contract test was defined.
    in_memory = "Normandy.Behaviours.SessionStore.InMemory"

    module =
      example_test_module("MyAppTest.SessionStoreTest", [
        {"impl: MyApp.SessionStore", "impl: #{in_memory}"},
        {"new: {MyApp.SessionStore, :new, []}", "new: {#{in_memory}, :new, []}"}
      ])

    reference = length(ContractReference.__ex_unit__().tests)
    assert reference > 0
    assert length(module.__ex_unit__().tests) == reference
  end
end
