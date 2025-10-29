defmodule Normandy.Schema.ValidatorBasicTest do
  use ExUnit.Case, async: true

  alias Normandy.Schema.Validator

  describe "basic validation" do
    defmodule SimpleSchema do
      use Normandy.Schema

      schema do
        field(:name, :string, required: true)
        field(:age, :integer, minimum: 0)
        field(:email, :string)
      end
    end

    test "validates correct data" do
      data = %{name: "Alice", age: 30, email: "alice@example.com"}
      assert {:ok, ^data} = Validator.validate(SimpleSchema, data)
    end

    test "validates with missing optional fields" do
      data = %{name: "Alice"}
      assert {:ok, ^data} = Validator.validate(SimpleSchema, data)
    end

    test "returns error for missing required field" do
      data = %{age: 30}
      assert {:error, errors} = Validator.validate(SimpleSchema, data)
      assert length(errors) == 1
      assert hd(errors).constraint == :required
      assert hd(errors).path == [:name]
    end

    test "returns error for wrong type" do
      data = %{name: 123}
      assert {:error, errors} = Validator.validate(SimpleSchema, data)
      assert length(errors) == 1
      assert hd(errors).constraint == :type
    end

    test "returns error for number below minimum" do
      data = %{name: "Alice", age: -1}
      assert {:error, errors} = Validator.validate(SimpleSchema, data)
      assert length(errors) == 1
      assert hd(errors).constraint == :minimum
    end
  end

  describe "validate!/2" do
    defmodule RequiredSchema do
      use Normandy.Schema

      schema do
        field(:name, :string, required: true)
      end
    end

    test "returns data when validation succeeds" do
      data = %{name: "Alice"}
      assert ^data = Validator.validate!(RequiredSchema, data)
    end

    test "raises ValidationError when validation fails" do
      assert_raise Normandy.Schema.ValidationError, fn ->
        Validator.validate!(RequiredSchema, %{})
      end
    end
  end

  describe "string constraints" do
    defmodule StringSchema do
      use Normandy.Schema

      schema do
        field(:username, :string, min_length: 3, max_length: 20)
        field(:code, :string, pattern: "^[A-Z]{3}[0-9]{3}$")
      end
    end

    test "validates string length" do
      assert {:ok, _} = Validator.validate(StringSchema, %{username: "alice"})
      assert {:ok, _} = Validator.validate(StringSchema, %{username: "bob"})
    end

    test "returns error for string too short" do
      assert {:error, errors} = Validator.validate(StringSchema, %{username: "ab"})
      assert length(errors) == 1
      assert hd(errors).constraint == :min_length
    end

    test "returns error for string too long" do
      assert {:error, errors} =
               Validator.validate(StringSchema, %{username: "verylongusernamethatexceedslimit"})

      assert length(errors) == 1
      assert hd(errors).constraint == :max_length
    end

    test "validates pattern match" do
      assert {:ok, _} = Validator.validate(StringSchema, %{code: "ABC123"})
    end

    test "returns error for pattern mismatch" do
      assert {:error, errors} = Validator.validate(StringSchema, %{code: "abc123"})
      assert hd(errors).constraint == :pattern
    end
  end

  describe "array constraints" do
    defmodule ArraySchema do
      use Normandy.Schema

      schema do
        field(:tags, {:array, :string}, min_items: 1, max_items: 5)
        field(:ids, {:array, :integer}, unique_items: true)
      end
    end

    test "validates array size" do
      assert {:ok, _} = Validator.validate(ArraySchema, %{tags: ["one", "two"]})
    end

    test "returns error for too few items" do
      assert {:error, errors} = Validator.validate(ArraySchema, %{tags: []})
      assert hd(errors).constraint == :min_items
    end

    test "returns error for too many items" do
      assert {:error, errors} =
               Validator.validate(ArraySchema, %{
                 tags: ["one", "two", "three", "four", "five", "six"]
               })

      assert hd(errors).constraint == :max_items
    end

    test "validates unique items" do
      assert {:ok, _} = Validator.validate(ArraySchema, %{ids: [1, 2, 3]})
    end

    test "returns error for duplicate items" do
      assert {:error, errors} = Validator.validate(ArraySchema, %{ids: [1, 2, 2, 3]})
      assert hd(errors).constraint == :unique_items
    end
  end

  describe "nested schemas" do
    defmodule Address do
      use Normandy.Schema

      schema do
        field(:city, :string, required: true)
        field(:zip, :string)
      end
    end

    defmodule Person do
      use Normandy.Schema

      schema do
        field(:name, :string, required: true)
        field(:address, Address)
      end
    end

    test "validates nested schema" do
      data = %{name: "Alice", address: %{city: "Springfield", zip: "12345"}}
      assert {:ok, _} = Validator.validate(Person, data)
    end

    test "returns error for invalid nested field" do
      data = %{name: "Alice", address: %{zip: "12345"}}
      assert {:error, errors} = Validator.validate(Person, data)
      assert Enum.any?(errors, fn e -> e.path == [:address, :city] end)
    end
  end

  describe "string format validation" do
    defmodule FormatSchema do
      use Normandy.Schema

      schema do
        field(:email, :string, format: "email")
        field(:website, :string, format: "uri")
        field(:id, :string, format: "uuid")
        field(:timestamp, :string, format: "date-time")
        field(:ip, :string, format: "ipv4")
        field(:ipv6_addr, :string, format: "ipv6")
      end
    end

    test "validates email format" do
      assert {:ok, _} = Validator.validate(FormatSchema, %{email: "user@example.com"})
      assert {:ok, _} = Validator.validate(FormatSchema, %{email: "test.email+tag@domain.co.uk"})
    end

    test "returns error for invalid email format" do
      assert {:error, errors} = Validator.validate(FormatSchema, %{email: "not-an-email"})
      assert hd(errors).constraint == :format
      assert hd(errors).format == "email"
    end

    test "validates URI format" do
      assert {:ok, _} = Validator.validate(FormatSchema, %{website: "https://example.com"})
      assert {:ok, _} = Validator.validate(FormatSchema, %{website: "ftp://files.example.org"})
    end

    test "returns error for invalid URI format" do
      assert {:error, errors} = Validator.validate(FormatSchema, %{website: "not a uri"})
      assert hd(errors).constraint == :format
      assert hd(errors).format == "uri"
    end

    test "validates UUID format" do
      assert {:ok, _} =
               Validator.validate(FormatSchema, %{id: "550e8400-e29b-41d4-a716-446655440000"})
    end

    test "returns error for invalid UUID format" do
      assert {:error, errors} = Validator.validate(FormatSchema, %{id: "not-a-uuid"})
      assert hd(errors).constraint == :format
      assert hd(errors).format == "uuid"
    end

    test "validates ISO 8601 date-time format" do
      assert {:ok, _} = Validator.validate(FormatSchema, %{timestamp: "2024-01-15T10:30:00Z"})

      assert {:ok, _} =
               Validator.validate(FormatSchema, %{timestamp: "2024-01-15T10:30:00.123+05:30"})
    end

    test "returns error for invalid date-time format" do
      assert {:error, errors} = Validator.validate(FormatSchema, %{timestamp: "not a datetime"})
      assert hd(errors).constraint == :format
      assert hd(errors).format == "date-time"
    end

    test "validates IPv4 format" do
      assert {:ok, _} = Validator.validate(FormatSchema, %{ip: "192.168.1.1"})
      assert {:ok, _} = Validator.validate(FormatSchema, %{ip: "0.0.0.0"})
    end

    test "returns error for invalid IPv4 format" do
      assert {:error, errors} = Validator.validate(FormatSchema, %{ip: "256.1.1.1"})
      assert hd(errors).constraint == :format
      assert hd(errors).format == "ipv4"
    end

    test "validates IPv6 format" do
      assert {:ok, _} =
               Validator.validate(FormatSchema, %{
                 ipv6_addr: "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
               })

      assert {:ok, _} = Validator.validate(FormatSchema, %{ipv6_addr: "::1"})
    end

    test "returns error for invalid IPv6 format" do
      assert {:error, errors} = Validator.validate(FormatSchema, %{ipv6_addr: "not-ipv6"})
      assert hd(errors).constraint == :format
      assert hd(errors).format == "ipv6"
    end
  end
end
