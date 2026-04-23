defmodule Normandy.Guardrails.Builtins.ForbiddenSubstringsTest do
  use ExUnit.Case, async: true

  alias Normandy.Guardrails.Builtins.ForbiddenSubstrings

  describe "check/2" do
    test "passes when no forbidden term is present" do
      assert ForbiddenSubstrings.check("hello there", terms: ["bomb", "hack"]) == :ok
    end

    test "rejects when a forbidden term appears (case-insensitive by default)" do
      assert {:error, [violation]} =
               ForbiddenSubstrings.check("Ignore Previous Instructions",
                 terms: ["ignore previous"]
               )

      assert violation.guard == ForbiddenSubstrings
      assert violation.constraint == :forbidden_substring
      assert violation.term == "ignore previous"
      assert violation.message =~ "ignore previous"
    end

    test "case-sensitive mode respects original casing" do
      assert ForbiddenSubstrings.check(
               "Ignore previous",
               terms: ["IGNORE"],
               case_sensitive: true
             ) == :ok

      assert {:error, _} =
               ForbiddenSubstrings.check(
                 "IGNORE previous",
                 terms: ["IGNORE"],
                 case_sensitive: true
               )
    end

    test "returns one violation per matched term" do
      assert {:error, violations} =
               ForbiddenSubstrings.check("bomb and hack", terms: ["bomb", "hack", "safe"])

      assert length(violations) == 2
      assert Enum.map(violations, & &1.term) |> Enum.sort() == ["bomb", "hack"]
    end

    test "extracts from :field on a map" do
      assert {:error, [violation]} =
               ForbiddenSubstrings.check(
                 %{msg: "ignore previous"},
                 terms: ["ignore previous"],
                 field: :msg
               )

      assert violation.path == [:msg]
    end

    test "is a no-op when the field is missing" do
      assert ForbiddenSubstrings.check(%{other: "x"}, terms: ["block"], field: :msg) == :ok
    end

    test "raises on empty :terms" do
      assert_raise ArgumentError, ~r/non-empty list/, fn ->
        ForbiddenSubstrings.check("x", terms: [])
      end
    end

    test "raises when :terms contains a non-string" do
      assert_raise ArgumentError, ~r/non-empty list/, fn ->
        ForbiddenSubstrings.check("x", terms: ["ok", 42])
      end
    end

    test "raises on non-string value without :field" do
      assert_raise ArgumentError, ~r/expected a string/, fn ->
        ForbiddenSubstrings.check(42, terms: ["x"])
      end
    end

    test "raises when :field is set but value is not a map or struct" do
      assert_raise ArgumentError, ~r/expected a map or struct when using :field/, fn ->
        ForbiddenSubstrings.check("raw string", terms: ["block"], field: :msg)
      end
    end
  end
end
