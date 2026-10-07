defmodule Normandy.Schema.FieldOptionsTest do
  @moduledoc "Field option values are checked when the schema compiles."
  use ExUnit.Case, async: true

  defp compile(field) do
    Code.compile_string("""
    defmodule Normandy.Schema.FieldOptionsTest.S#{System.unique_integer([:positive])} do
      use Normandy.Schema

      schema do
        #{field}
      end
    end
    """)
  end

  test "a length option must be a non-negative integer" do
    assert_raise ArgumentError,
                 ~r/option :min_length for field :name must be a non-negative integer, got: "3"/,
                 fn ->
                   compile(~s|field(:name, :string, min_length: "3")|)
                 end
  end

  test "a bound must be a number" do
    assert_raise ArgumentError, ~r/option :minimum for field :n must be a number, got: "0"/, fn ->
      compile(~s|field(:n, :integer, minimum: "0")|)
    end
  end

  test "a pattern must be a string that compiles as a regex" do
    assert_raise ArgumentError, ~r/option :pattern for field :code must be a regex string/, fn ->
      compile(~s|field(:code, :string, pattern: ~r/x/)|)
    end

    assert_raise ArgumentError, ~r/option :pattern for field :code is not a valid regex/, fn ->
      compile(~s|field(:code, :string, pattern: "(")|)
    end
  end

  test "flags must be booleans and lists must be lists" do
    assert_raise ArgumentError,
                 ~r/option :required for field :name must be a boolean, got: "yes"/,
                 fn ->
                   compile(~s|field(:name, :string, required: "yes")|)
                 end

    assert_raise ArgumentError, ~r/option :enum for field :kind must be a list, got: "abc"/, fn ->
      compile(~s|field(:kind, :string, enum: "abc")|)
    end

    assert_raise ArgumentError, ~r/option :any_of for field :v must be a list, got: :foo/, fn ->
      compile(~s|field(:v, :any, any_of: :foo)|)
    end
  end

  test "Ecto options that did nothing are unknown options" do
    for opt <- ~w(defaults type where references) do
      assert_raise ArgumentError, ~r{^field/3: unknown option :#{opt} for field :name; }, fn ->
        compile(~s|field(:name, :string, #{opt}: :x)|)
      end
    end
  end

  test "an unknown option is named with its field and the options field/3 takes" do
    message =
      "field/3: unknown option :defaults for field :name; expected one of: :all_of, " <>
        ":any_of, :compute, :default, :description, :else_schema, :enum, :examples, " <>
        ":exclusive_maximum, :exclusive_minimum, :format, :if_schema, " <>
        ":include_in_json_schema, :max_items, :max_length, :maximum, :min_items, " <>
        ":min_length, :minimum, :one_of, :pattern, :redact, :required, " <>
        ":skip_default_validation, :then_schema, :unique_items, :virtual"

    assert_raise ArgumentError, message, fn ->
      compile(~s|field(:name, :string, defaults: :x)|)
    end
  end

  test "a second schema in one module is an ArgumentError naming the first" do
    source = """
    defmodule Normandy.Schema.FieldOptionsTest.Twice do
      use Normandy.Schema

      schema do
        field(:a, :string)
      end

      io_schema "again" do
        field(:b, :string)
      end
    end
    """

    assert_raise ArgumentError,
                 "schema already defined for Normandy.Schema.FieldOptionsTest.Twice on line 4; " <>
                   "a module defines one schema (schema/1 or io_schema/2)",
                 fn -> Code.compile_string(source) end
  end

  test "valid options compile" do
    assert [{_, _}] =
             compile(
               ~s|field(:name, :string, min_length: 1, max_length: 5, pattern: "^a", required: true, enum: ["a"], description: "d")|
             )
  end
end
