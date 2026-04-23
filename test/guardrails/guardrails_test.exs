defmodule Normandy.GuardrailsTest do
  use ExUnit.Case, async: true

  alias Normandy.Guardrails

  defmodule AlwaysPass do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(_value, _opts), do: :ok
  end

  defmodule AlwaysFail do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(_value, opts) do
      tag = Keyword.get(opts, :tag, :blocked)

      {:error,
       [
         %{
           guard: __MODULE__,
           path: [],
           message: "blocked by #{tag}",
           constraint: tag
         }
       ]}
    end
  end

  defmodule RecordsOpts do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(value, opts) do
      send(self(), {__MODULE__, value, opts})
      :ok
    end
  end

  defmodule ReturnsGarbage do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(_value, _opts), do: :maybe
  end

  describe "run/2" do
    test "returns {:ok, value} for an empty guard list" do
      assert Guardrails.run([], "anything") == {:ok, "anything"}
    end

    test "returns {:ok, value} when every guard passes" do
      assert Guardrails.run([AlwaysPass, AlwaysPass], %{a: 1}) == {:ok, %{a: 1}}
    end

    test "short-circuits on first failure" do
      # Second guard would overwrite violations if it ran — verifies halt.
      guards = [{AlwaysFail, tag: :first}, {AlwaysFail, tag: :second}]

      assert {:error, [violation]} = Guardrails.run(guards, "x")
      assert violation.constraint == :first
      assert violation.guard == AlwaysFail
    end

    test "bare module atoms are treated as {mod, []}" do
      assert Guardrails.run([AlwaysPass], "x") == {:ok, "x"}
    end

    test "passes opts through to check/2 and value unchanged between guards" do
      Guardrails.run([{RecordsOpts, tag: :a}, {RecordsOpts, tag: :b}], :value)

      assert_received {RecordsOpts, :value, [tag: :a]}
      assert_received {RecordsOpts, :value, [tag: :b]}
    end

    test "raises on malformed guard return" do
      assert_raise ArgumentError, ~r/expected .*check\/2 to return :ok/, fn ->
        Guardrails.run([ReturnsGarbage], "x")
      end
    end

    test "raises on malformed guard spec" do
      assert_raise ArgumentError, ~r/invalid guard spec/, fn ->
        Guardrails.run(["not_a_module"], "x")
      end
    end
  end
end
