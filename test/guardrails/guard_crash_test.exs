defmodule Normandy.Guardrails.GuardCrashTest do
  # SEC-4: :on_error covers exits and throws, and a SemanticScope classifier's own
  # KeyError or ArgumentError is host code, not the builtin's configuration.
  use ExUnit.Case, async: true

  alias Normandy.Guardrails
  alias Normandy.Guardrails.Builtins.SemanticScope
  alias Normandy.Guardrails.GuardError

  defmodule ExitsGuard do
    @moduledoc false
    @behaviour Normandy.Guardrails.Guard
    @impl true
    def check(_value, _opts), do: exit({:timeout, {GenServer, :call, [:svc, "SECRET-ARG", 5]}})
  end

  defmodule ThrowsGuard do
    @moduledoc false
    @behaviour Normandy.Guardrails.Guard
    @impl true
    def check(_value, _opts), do: throw({:nope, "SECRET-THROWN"})
  end

  defmodule Elixir.Normandy.Guardrails.Builtins.HostLookalike do
    @moduledoc false
    @behaviour Normandy.Guardrails.Guard
    @impl true
    def check(_value, _opts), do: raise(ArgumentError, "host bug")
  end

  @scope SemanticScope

  defp classifiers do
    %{
      exit: fn _v, _c -> exit({:timeout, {GenServer, :call, [:svc, "SECRET-ARG", 5]}}) end,
      key_error: fn _v, _c -> Map.fetch!(Function.identity(%{token: "SECRET-MAP"}), :missing) end,
      argument_error: fn _v, _c -> raise ArgumentError, "SECRET-MESSAGE" end,
      throw: fn _v, _c -> throw("SECRET-THROWN") end
    }
  end

  @expected %{
    exit: "guard Normandy.Guardrails.Builtins.SemanticScope crashed: host code exited: :timeout",
    key_error:
      "guard Normandy.Guardrails.Builtins.SemanticScope crashed: host code raised KeyError",
    argument_error:
      "guard Normandy.Guardrails.Builtins.SemanticScope crashed: host code raised ArgumentError",
    throw: "guard Normandy.Guardrails.Builtins.SemanticScope crashed: host code threw"
  }

  test "a host guard named under the Builtins namespace is still a host guard" do
    guard = Normandy.Guardrails.Builtins.HostLookalike
    assert Guardrails.run([{guard, on_error: :open}], "x") == {:ok, "x"}
    assert {:error, [v]} = Guardrails.run([{guard, on_error: :closed}], "x")
    assert v.constraint == :guard_error
  end

  describe "a guard module that exits or throws" do
    test ":open admits" do
      for guard <- [ExitsGuard, ThrowsGuard] do
        assert Guardrails.run([{guard, on_error: :open}], "x") == {:ok, "x"}
      end
    end

    test ":closed is a :guard_error violation naming the exit tag, never its terms" do
      assert {:error, [exited]} = Guardrails.run([{ExitsGuard, on_error: :closed}], "x")
      assert exited.constraint == :guard_error
      assert exited.message == "guard #{inspect(ExitsGuard)} exited: :timeout"

      assert {:error, [threw]} = Guardrails.run([{ThrowsGuard, on_error: :closed}], "x")
      assert threw.message == "guard #{inspect(ThrowsGuard)} threw"

      refute inspect([exited, threw], limit: :infinity, printable_limit: :infinity) =~ "SECRET"
    end

    test ":reraise lets the exit and the throw through, as before" do
      assert catch_exit(Guardrails.run([ExitsGuard], "x")) ==
               {:timeout, {GenServer, :call, [:svc, "SECRET-ARG", 5]}}

      assert catch_throw(Guardrails.run([ThrowsGuard], "x")) == {:nope, "SECRET-THROWN"}
    end
  end

  describe "a SemanticScope classifier that fails" do
    test ":open admits every kind of failure" do
      for {_kind, classifier} <- classifiers() do
        assert Guardrails.run([{@scope, classifier: classifier, on_error: :open}], "q") ==
                 {:ok, "q"}
      end
    end

    test ":closed gives a :guard_error naming the failure's tag only" do
      for {kind, classifier} <- classifiers() do
        assert {:error, [violation]} =
                 Guardrails.run([{@scope, classifier: classifier, on_error: :closed}], "q")

        assert violation.constraint == :guard_error
        assert violation.message == Map.fetch!(@expected, kind)
        refute inspect(violation, limit: :infinity, printable_limit: :infinity) =~ "SECRET"
      end
    end

    test "a failing fast_path is handled the same way" do
      guard =
        {@scope,
         classifier: fn _, _ -> :allow end, fast_path: classifiers().exit, on_error: :closed}

      assert {:error, [%{message: message}]} = Guardrails.run([guard], "q")
      assert message == @expected.exit
    end

    test ":reraise lets the host's own exception through unchanged" do
      assert_raise KeyError, fn ->
        Guardrails.run([{@scope, classifier: classifiers().key_error}], "q")
      end

      assert catch_exit(Guardrails.run([{@scope, classifier: classifiers().exit}], "q")) ==
               {:timeout, {GenServer, :call, [:svc, "SECRET-ARG", 5]}}
    end

    test "the guard's own configuration errors still raise under :open and :closed" do
      for policy <- [:open, :closed] do
        assert_raise KeyError, ~r/key :classifier not found/, fn ->
          Guardrails.run([{@scope, on_error: policy}], "q")
        end

        assert_raise ArgumentError, ~r/:classifier must return/, fn ->
          Guardrails.run([{@scope, classifier: fn _, _ -> :nope end, on_error: policy}], "q")
        end
      end
    end
  end

  test "GuardError's message never shows the reason's terms" do
    for {kind, reason, message} <- [
          {:error, %KeyError{key: :k, term: %{token: "SECRET"}}, "host code raised KeyError"},
          {:exit, {:shutdown, "SECRET"}, "host code exited: :shutdown"},
          {:exit, "SECRET", "host code exited: a string (6 bytes)"},
          {:throw, "SECRET", "host code threw"}
        ] do
      assert Exception.message(%GuardError{kind: kind, reason: reason}) == message
    end
  end
end
