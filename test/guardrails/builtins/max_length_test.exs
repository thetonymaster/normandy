defmodule Normandy.Guardrails.Builtins.MaxLengthTest do
  use ExUnit.Case, async: true

  alias Normandy.Guardrails.Builtins.MaxLength

  describe "check/2 with a raw string" do
    test "passes when length is at the limit" do
      assert MaxLength.check("hello", limit: 5) == :ok
    end

    test "passes when length is under the limit" do
      assert MaxLength.check("hi", limit: 5) == :ok
    end

    test "rejects when length exceeds the limit" do
      assert {:error, [violation]} = MaxLength.check("too long", limit: 5)
      assert violation.guard == MaxLength
      assert violation.constraint == :max_length
      assert violation.path == []
      assert violation.limit == 5
      assert violation.message =~ "5 characters"
    end

    test "counts graphemes, not bytes" do
      # "é" is 2 bytes but 1 grapheme
      assert MaxLength.check("é", limit: 1) == :ok
    end
  end

  describe "check/2 with :field" do
    test "extracts the field from a map" do
      assert MaxLength.check(%{msg: "hi"}, limit: 5, field: :msg) == :ok
    end

    test "rejects when the extracted field is over the limit" do
      assert {:error, [violation]} = MaxLength.check(%{msg: "too long"}, limit: 5, field: :msg)
      assert violation.path == [:msg]
    end

    test "is a no-op when the field is missing" do
      assert MaxLength.check(%{other: "x"}, limit: 5, field: :msg) == :ok
    end

    test "is a no-op when the field value is nil" do
      assert MaxLength.check(%{msg: nil}, limit: 5, field: :msg) == :ok
    end

    test "raises when the extracted value is not a string" do
      assert_raise ArgumentError, ~r/expected a string at field :msg/, fn ->
        MaxLength.check(%{msg: 42}, limit: 5, field: :msg)
      end
    end
  end

  describe "check/2 argument validation" do
    test "raises without :limit" do
      assert_raise KeyError, fn ->
        MaxLength.check("x", [])
      end
    end

    test "raises on non-positive :limit" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        MaxLength.check("x", limit: 0)
      end
    end

    test "raises on non-string value without :field" do
      assert_raise ArgumentError, ~r/expected a string/, fn ->
        MaxLength.check(42, limit: 5)
      end
    end
  end
end
