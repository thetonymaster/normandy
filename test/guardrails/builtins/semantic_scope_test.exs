defmodule NormandyTest.Guardrails.SemanticScopeTest do
  use ExUnit.Case, async: true

  alias Normandy.Guardrails
  alias Normandy.Guardrails.Builtins.SemanticScope

  # Classifier that records each call (value + context) against the test pid and
  # returns a fixed verdict — lets a test prove whether the classifier ran.
  defp recording_classifier(verdict) do
    test = self()

    fn value, context ->
      send(test, {:classifier, value, context})
      verdict
    end
  end

  describe "fast_path" do
    test ":admit short-circuits without invoking the classifier" do
      opts = [classifier: recording_classifier(:allow), fast_path: fn _v, _c -> :admit end]

      assert SemanticScope.check("anything", opts) == :ok
      refute_received {:classifier, _, _}
    end

    test ":needs_classifier defers to the classifier" do
      opts = [
        classifier: recording_classifier(:allow),
        fast_path: fn _v, _c -> :needs_classifier end
      ]

      assert SemanticScope.check("q", opts) == :ok
      assert_received {:classifier, "q", _}
    end

    test "defaults to :needs_classifier when omitted" do
      assert SemanticScope.check("q", classifier: recording_classifier(:allow)) == :ok
      assert_received {:classifier, "q", _}
    end

    test "raises on an invalid fast_path return" do
      opts = [classifier: recording_classifier(:allow), fast_path: fn _v, _c -> :nonsense end]

      assert_raise ArgumentError, ~r/:fast_path/, fn ->
        SemanticScope.check("q", opts)
      end
    end
  end

  describe "classifier verdict" do
    test ":allow passes" do
      assert SemanticScope.check("q", classifier: fn _v, _c -> :allow end) == :ok
    end

    test "{:block, reason} becomes a violation carrying reason as :constraint" do
      assert {:error, [violation]} =
               SemanticScope.check("q", classifier: fn _v, _c -> {:block, :off_topic} end)

      assert violation.constraint == :off_topic
      assert violation.guard == SemanticScope
      assert violation.path == []
    end

    test "raises on an invalid classifier return" do
      assert_raise ArgumentError, ~r/:classifier/, fn ->
        SemanticScope.check("q", classifier: fn _v, _c -> :nope end)
      end
    end

    test "a missing :classifier raises KeyError" do
      assert_raise KeyError, fn ->
        SemanticScope.check("q", [])
      end
    end
  end

  describe "context (check/3)" do
    test "threads context to both fast_path and classifier" do
      test = self()

      fast_path = fn v, c ->
        send(test, {:fast, v, c})
        :needs_classifier
      end

      classifier = fn v, c ->
        send(test, {:clf, v, c})
        :allow
      end

      assert SemanticScope.check("q", [classifier: classifier, fast_path: fast_path], %{
               locale: "es"
             }) ==
               :ok

      assert_received {:fast, "q", %{locale: "es"}}
      assert_received {:clf, "q", %{locale: "es"}}
    end

    test "check/2 delegates with an empty context" do
      test = self()

      classifier = fn _v, c ->
        send(test, {:ctx, c})
        :allow
      end

      assert SemanticScope.check("q", classifier: classifier) == :ok
      assert_received {:ctx, ctx}
      assert ctx == %{}
    end
  end

  describe "integration with Guardrails.run/3" do
    test "threads run/3 context and blocks via the classifier's reason" do
      classifier = fn _v, %{topic: t} -> if t == :ok, do: :allow, else: {:block, :off_topic} end
      guards = [{SemanticScope, classifier: classifier}]

      assert Guardrails.run(guards, "q", %{topic: :ok}) == {:ok, "q"}
      assert {:error, [v]} = Guardrails.run(guards, "q", %{topic: :bad})
      assert v.constraint == :off_topic
    end

    test "a crashing classifier honours on_error: :open (fails open)" do
      classifier = fn _v, _c -> raise "inference down" end

      assert Guardrails.run([{SemanticScope, classifier: classifier, on_error: :open}], "q", %{}) ==
               {:ok, "q"}
    end

    test "a crashing classifier honours on_error: :closed (guard_error)" do
      classifier = fn _v, _c -> raise "inference down" end

      assert {:error, [v]} =
               Guardrails.run(
                 [{SemanticScope, classifier: classifier, on_error: :closed}],
                 "q",
                 %{}
               )

      assert v.constraint == :guard_error
    end
  end
end
