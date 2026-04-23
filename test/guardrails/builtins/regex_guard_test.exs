defmodule Normandy.Guardrails.Builtins.RegexGuardTest do
  use ExUnit.Case, async: true

  alias Normandy.Guardrails.Builtins.RegexGuard

  @ssn_pattern ~r/\b\d{3}-\d{2}-\d{4}\b/

  describe "deny mode (default)" do
    test "passes when no pattern matches" do
      assert RegexGuard.check("no digits here", patterns: [@ssn_pattern]) == :ok
    end

    test "rejects when a deny pattern matches" do
      assert {:error, [violation]} =
               RegexGuard.check("SSN 123-45-6789 leaked", patterns: [@ssn_pattern])

      assert violation.guard == RegexGuard
      assert violation.constraint == :regex_deny
      assert Regex.source(violation.pattern) == Regex.source(@ssn_pattern)
    end

    test "returns one violation per matched pattern" do
      assert {:error, violations} =
               RegexGuard.check(
                 "abc",
                 patterns: [~r/a/, ~r/b/, ~r/z/]
               )

      assert length(violations) == 2
    end

    test "missing field is a no-op in deny mode" do
      assert RegexGuard.check(%{other: "x"}, patterns: [@ssn_pattern], field: :msg) == :ok
    end
  end

  describe "require mode" do
    test "passes when at least one pattern matches" do
      assert RegexGuard.check("greeting: hello", patterns: [~r/hello/], mode: :require) == :ok
    end

    test "rejects when no pattern matches" do
      assert {:error, [violation]} =
               RegexGuard.check("no match", patterns: [~r/hello/], mode: :require)

      assert violation.constraint == :regex_require
    end

    test "missing field fails in require mode" do
      assert {:error, [violation]} =
               RegexGuard.check(
                 %{other: "x"},
                 patterns: [~r/hello/],
                 mode: :require,
                 field: :msg
               )

      assert violation.constraint == :regex_require
      assert violation.path == [:msg]
    end
  end

  describe "argument validation" do
    test "raises on empty :patterns" do
      assert_raise ArgumentError, ~r/non-empty list of Regex/, fn ->
        RegexGuard.check("x", patterns: [])
      end
    end

    test "raises on non-Regex entries" do
      assert_raise ArgumentError, ~r/non-empty list of Regex/, fn ->
        RegexGuard.check("x", patterns: ["not a regex"])
      end
    end

    test "raises on invalid :mode" do
      assert_raise ArgumentError, ~r/:mode must be/, fn ->
        RegexGuard.check("x", patterns: [~r/x/], mode: :other)
      end
    end
  end
end
