defmodule Normandy.Schema.ValidatorKeywordsTest do
  use ExUnit.Case, async: true

  alias Normandy.Schema.Validator

  defmodule EmailContact do
    use Normandy.Schema

    schema do
      field(:email, :string, required: true)
    end
  end

  defmodule PhoneContact do
    use Normandy.Schema

    schema do
      field(:phone, :string, required: true)
    end
  end

  defmodule Fields do
    use Normandy.Schema

    schema do
      field(:id, :any, one_of: [%{type: :string, format: "uuid"}, %{type: :integer, minimum: 1}])
      field(:name, :string, any_of: [%{minLength: 3}, %{pattern: "^x"}])
      field(:contact, :map, one_of: [EmailContact, PhoneContact])

      field(:subscription, :map,
        if_schema: %{properties: %{type: %{const: "premium"}}, required: [:type]},
        then_schema: %{properties: %{price: %{minimum: 100}}}
      )

      field(:count, :any, all_of: [%{multipleOf: 5}])
      field(:not_string, :any, all_of: [%{not: %{type: :string}}])

      field(:closed, :map,
        all_of: [%{properties: %{a: %{type: :integer}}, additionalProperties: false}]
      )

      field(:scores, {:map, :integer})
      field(:kind, :any, all_of: [%{const: "a"}])
      field(:prefixed, :map, all_of: [%{patternProperties: %{"^n_" => %{type: :integer}}}])
    end
  end

  defp errors(data) do
    case Validator.validate(Fields, data) do
      {:ok, _} -> []
      {:error, errors} -> Enum.map(errors, &{&1.path, &1.constraint})
    end
  end

  describe "composition on a field" do
    test "one_of checks each alternative's own constraints" do
      assert errors(%{id: 5}) == []
      assert errors(%{id: "6f1c1e4a-5b7d-4c8e-9f0a-1b2c3d4e5f60"}) == []
      assert [{[:id], :oneOf}] = errors(%{id: "not-a-uuid"})
      assert [{[:id], :oneOf}] = errors(%{id: 0})
    end

    test "any_of on a string field" do
      assert errors(%{name: "abc"}) == []
      assert errors(%{name: "xy"}) == []
      assert [{[:name], :anyOf}] = errors(%{name: "ab"})
    end

    test "one_of with schema modules on a :map field" do
      assert errors(%{contact: %{email: "a@b.c"}}) == []
      assert [{[:contact], :oneOf}] = errors(%{contact: %{}})
      assert [{[:contact], :oneOf}] = errors(%{contact: %{email: "a", phone: "1"}})
    end
  end

  describe "if/then on a field, with const" do
    test "then applies only when the if condition holds" do
      assert errors(%{subscription: %{type: "basic", price: 1}}) == []
      assert errors(%{subscription: %{type: "premium", price: 150}}) == []

      assert [{[:subscription, :price], :minimum}] =
               errors(%{subscription: %{type: "premium", price: 1}})
    end
  end

  describe "keywords that were ignored" do
    test "multipleOf" do
      assert errors(%{count: 10}) == []
      assert [{[:count], :multiple_of}] = errors(%{count: 7})
    end

    test "not" do
      assert errors(%{not_string: 1}) == []
      assert [{[:not_string], :not}] = errors(%{not_string: "s"})
    end

    test "additionalProperties: false rejects keys outside properties" do
      assert errors(%{closed: %{a: 1}}) == []
      assert [{[:closed, :b], :additional_properties}] = errors(%{closed: %{a: 1, b: 2}})
    end

    test "a {:map, inner} field checks every value against inner" do
      assert errors(%{scores: %{x: 1}}) == []
      assert [{[:scores, :x], :type}] = errors(%{scores: %{x: "s"}})
    end

    test "patternProperties checks the values of matching keys" do
      assert errors(%{prefixed: %{"n_a" => 1, "other" => "s"}}) == []
      assert [{[:prefixed, "n_a"], :type}] = errors(%{prefixed: %{"n_a" => "s"}})
    end

    test "const" do
      assert errors(%{kind: "a"}) == []
      assert [{[:kind], :const}] = errors(%{kind: "b"})
    end
  end
end
