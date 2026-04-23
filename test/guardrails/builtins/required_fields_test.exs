defmodule Normandy.Guardrails.Builtins.RequiredFieldsTest do
  use ExUnit.Case, async: true

  alias Normandy.Guardrails.Builtins.RequiredFields

  defmodule Sample do
    defstruct [:result, :detail, :note]
  end

  describe "check/2" do
    test "passes when all fields are populated" do
      value = %Sample{result: "ok", detail: "d", note: "n"}
      assert RequiredFields.check(value, fields: [:result, :detail]) == :ok
    end

    test "passes for plain maps with all fields present" do
      assert RequiredFields.check(%{a: 1, b: 2}, fields: [:a, :b]) == :ok
    end

    test "rejects nil fields" do
      value = %Sample{result: nil, detail: "d", note: nil}

      assert {:error, violations} = RequiredFields.check(value, fields: [:result, :detail, :note])

      paths = Enum.map(violations, & &1.path) |> Enum.sort()
      assert paths == [[:note], [:result]]
      assert Enum.all?(violations, &(&1.constraint == :required_field))
      assert Enum.all?(violations, &(&1.guard == RequiredFields))
    end

    test "rejects missing keys in a plain map" do
      assert {:error, [violation]} = RequiredFields.check(%{a: 1}, fields: [:b])
      assert violation.path == [:b]
    end

    test "raises on empty :fields" do
      assert_raise ArgumentError, ~r/non-empty list of atoms/, fn ->
        RequiredFields.check(%{}, fields: [])
      end
    end

    test "raises on non-map value" do
      assert_raise ArgumentError, ~r/expected a map or struct/, fn ->
        RequiredFields.check("not a map", fields: [:a])
      end
    end
  end
end
