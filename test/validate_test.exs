defmodule NormandyTest.ValidateTest do
  use ExUnit.Case, async: true
  import Normandy.Validate

  defmodule TestTool do
    use Normandy.Schema

    schema do
      field(:one, :string, required: true, description: "field one")
      field(:two, :string, description: "field two")
    end

    def validate_schema(schema \\ %TestTool{}, params) do
      validate(schema, params)
    end
  end

  test "cast with valid string keys" do
    params = %{"one" => "one", "two" => "two"}
    struct = %TestTool{}

    validations = cast(struct, params, ~w(one two)a)

    assert validations.params == %{"one" => "one", "two" => "two"}
    assert validations.data == struct
    assert validations.changes == %{one: "one", two: "two"}
    assert validations.errors == []
    assert validations.required == []
    assert validations.valid?
    assert validations(validations) == []

    assert apply_changes(validations) == %TestTool{one: "one", two: "two"}
  end

  test "validate missing fields" do
    params = %{"one" => "one"}

    struct = %TestTool{}
    validations = TestTool.validate_schema(struct, params)

    assert validations.params == %{"one" => "one"}
    assert validations.data == struct
    assert validations.changes == %{one: "one"}
    assert validations.errors == [{:two, {"can't be blank", [validation: :required]}}]
    assert validations.required == [:one, :two]
    refute validations.valid?
  end

  test "validate/2" do
    params = %{"one" => "one", "two" => "two"}

    struct = %TestTool{}
    validations = TestTool.validate_schema(struct, params)

    assert validations.params == %{"one" => "one", "two" => "two"}
    assert validations.data == struct
    assert validations.changes == %{one: "one", two: "two"}
    assert validations.errors == []
    assert validations.required == [:one, :two]
    assert validations.valid?
    assert validations(validations) == []
  end

  test "validate/2 with invalid parameters" do
    params = %{"three" => "3", "four" => "4"}
    struct = %TestTool{}
    validations = TestTool.validate_schema(struct, params)

    assert validations.params == %{"three" => "3", "four" => "4"}
    assert validations.data == struct
    assert validations.changes == %{}

    assert validations.errors == [
             {:one, {"can't be blank", [validation: :required]}},
             {:two, {"can't be blank", [validation: :required]}}
           ]

    assert validations.required == [:one, :two]
    refute validations.valid?
    assert validations(validations) == []
  end

  test "invalid params" do
    params = %{"one" => :one}

    struct = %TestTool{}
    validations = TestTool.validate_schema(struct, params)

    assert validations.params == %{"one" => :one}
    assert validations.data == struct
    assert validations.changes == %{}

    assert validations.errors == [
             {:two, {"can't be blank", [validation: :required]}},
             {:one, {"is invalid", [type: :string, validation: :cast]}}
           ]

    assert validations.required == [:one, :two]
    refute validations.valid?
    assert validations(validations) == []
  end
end
