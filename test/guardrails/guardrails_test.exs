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

  defmodule RecordsContext do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(value, opts), do: check(value, opts, %{})

    @impl true
    def check(value, opts, context) do
      send(self(), {__MODULE__, value, opts, context})
      :ok
    end
  end

  defmodule RaisesError do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(_value, _opts), do: raise(RuntimeError, "boom")
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

  describe "run/3" do
    test "threads the context map to a guard implementing check/3" do
      Guardrails.run([RecordsContext], :value, %{locale: "es"})

      assert_received {RecordsContext, :value, [], %{locale: "es"}}
    end

    test "run/2 invokes check/3 guards with an empty context" do
      Guardrails.run([RecordsContext], :value)

      assert_received {RecordsContext, :value, [], %{}}
    end

    test "context-unaware guards (check/2 only) receive unchanged opts" do
      Guardrails.run([{RecordsOpts, tag: :a}], :value, %{locale: "es"})

      assert_received {RecordsOpts, :value, [tag: :a]}
    end
  end

  describe "run :on_error" do
    test "defaults to :reraise — a crashing guard propagates" do
      assert_raise RuntimeError, "boom", fn ->
        Guardrails.run([RaisesError], "x")
      end
    end

    test ":open treats a crashing guard as a pass" do
      assert Guardrails.run([{RaisesError, on_error: :open}], "x") == {:ok, "x"}
    end

    test ":closed converts a crashing guard into a :guard_error violation" do
      assert {:error, [violation]} =
               Guardrails.run([{RaisesError, on_error: :closed}], "x")

      assert violation.constraint == :guard_error
      assert violation.guard == RaisesError
    end

    test "rejects an invalid :on_error value" do
      assert_raise ArgumentError, ~r/:on_error/, fn ->
        Guardrails.run([{RaisesError, on_error: :bogus}], "x")
      end
    end

    test ":open does not swallow a malformed-return contract error" do
      assert_raise ArgumentError, ~r/to return :ok/, fn ->
        Guardrails.run([{ReturnsGarbage, on_error: :open}], "x")
      end
    end
  end
end
