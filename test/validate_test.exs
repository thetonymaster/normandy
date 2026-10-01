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

  defmodule Numbers do
    use Normandy.Schema

    schema do
      field(:age, :integer, description: "age")
    end
  end

  describe "validate_number/3" do
    defp age_changeset(age), do: cast(%Numbers{}, %{age: age}, [:age])

    test "passes a value that meets the option" do
      assert validate_number(age_changeset(5), :age, greater_than: 0).valid?
    end

    test "reports a value that breaks the option" do
      cs = validate_number(age_changeset(0), :age, greater_than: 0)
      refute cs.valid?
      assert {"must be greater than %{number}", opts} = cs.errors[:age]
      assert opts[:number] == 0
    end

    test "a non-number option raises" do
      assert_raise ArgumentError, ~r/greater_than.*got: :zero/, fn ->
        validate_number(age_changeset(5), :age, greater_than: :zero)
      end
    end
  end

  defmodule Signup do
    use Normandy.Schema

    schema do
      field(:terms, :boolean, description: "terms")
      field(:password, :string, description: "password")
      field(:password_confirmation, :string, description: "confirmation")
      field(:tags, {:array, :string}, description: "tags")
      field(:role, :string, description: "role")
    end
  end

  describe "the other validators" do
    defp signup(params) do
      cast(%Signup{}, params, [:terms, :password, :password_confirmation, :tags, :role])
    end

    test "validate_acceptance accepts true and rejects false" do
      assert validate_acceptance(signup(%{terms: true}), :terms).valid?
      refute validate_acceptance(signup(%{terms: false}), :terms).valid?
    end

    test "validate_confirmation compares against the confirmation field" do
      assert validate_confirmation(
               signup(%{password: "a", password_confirmation: "a"}),
               :password
             ).valid?

      refute validate_confirmation(
               signup(%{password: "a", password_confirmation: "b"}),
               :password
             ).valid?
    end

    test "validate_subset checks every element" do
      assert validate_subset(signup(%{tags: ["a"]}), :tags, ["a", "b"]).valid?
      refute validate_subset(signup(%{tags: ["a", "z"]}), :tags, ["a", "b"]).valid?
    end

    test "validate_exclusion rejects listed values" do
      assert validate_exclusion(signup(%{role: "user"}), :role, ["admin"]).valid?
      refute validate_exclusion(signup(%{role: "admin"}), :role, ["admin"]).valid?
    end
  end
end
