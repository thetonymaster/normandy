defmodule Normandy.Guardrails.Builtins.FieldOptionTest do
  @moduledoc """
  A guard with `:field` set checks one field of a struct. A misspelled field
  must raise, not read as nil and let everything through.
  """
  use ExUnit.Case, async: true

  alias Normandy.Guardrails.Builtins.{ForbiddenSubstrings, MaxLength, RegexGuard}

  defmodule Answer do
    defstruct summary: nil
  end

  defp answer, do: %Answer{summary: "the secret plan"}

  test "a field the struct does not have raises, for every built-in guard" do
    for {guard, opts} <- [
          {MaxLength, limit: 3},
          {ForbiddenSubstrings, terms: ["secret"]},
          {RegexGuard, patterns: [~r/secret/], mode: :deny}
        ] do
      assert_raise ArgumentError, ~r/:summery is not a field of %.*Answer\{\}/, fn ->
        guard.check(answer(), Keyword.put(opts, :field, :summery))
      end
    end
  end

  test "a present field that is nil is still nothing to check" do
    assert :ok = MaxLength.check(%Answer{summary: nil}, limit: 3, field: :summary)
  end

  test "MaxLength raises for a non-map value with :field set, like its siblings" do
    assert_raise ArgumentError,
                 ~r/expected a map or struct when using :field :summary, got a string/,
                 fn ->
                   MaxLength.check("plain text", limit: 3, field: :summary)
                 end
  end

  test "the error names the value's type, not its content" do
    error =
      assert_raise ArgumentError, fn ->
        ForbiddenSubstrings.check("user secret text", terms: ["x"], field: :summary)
      end

    refute error.message =~ "user secret text"
  end
end
