defmodule Normandy.ValidateValidateTest do
  use ExUnit.Case, async: true

  alias Normandy.Validate

  defmodule Profile do
    use Normandy.Schema

    schema do
      field(:name, :string, required: true)
      field(:nickname, :string)
    end
  end

  test "validate/2 casts every field and requires only the required: true ones" do
    assert %Validate{valid?: true, changes: %{name: "Ana"}} =
             Validate.validate(%Profile{}, %{"name" => "Ana"})
  end

  test "validate/2 reports a missing required field" do
    assert %Validate{valid?: false, errors: [name: {"can't be blank", _}]} =
             Validate.validate(%Profile{}, %{"nickname" => "a"})
  end

  test "a required field holding only whitespace counts as blank" do
    assert %Validate{valid?: false, errors: [name: {"can't be blank", _}]} =
             Validate.validate(%Profile{name: "  \n"}, %{})
  end

  test "a required field with text around whitespace is present" do
    assert %Validate{valid?: true} = Validate.validate(%Profile{name: " Ana "}, %{})
  end
end
