defmodule NormandyTest.ParameterizedTypeTest do
  use ExUnit.Case, async: true

  alias Normandy.ParameterizedType

  defmodule EnumType do
    @moduledoc """
    A parameterized type that validates values against a list of allowed values.
    """
    use Normandy.ParameterizedType

    def init(opts) do
      values = Keyword.fetch!(opts, :values)
      %{values: values}
    end

    def type(_params), do: :string

    def cast(value, %{values: values}) when is_binary(value) do
      if value in values do
        {:ok, value}
      else
        :error
      end
    end

    def cast(value, %{values: values}) when is_atom(value) do
      string_value = Atom.to_string(value)

      if string_value in values do
        {:ok, string_value}
      else
        :error
      end
    end

    def cast(_value, _params), do: :error

    def load(value, _loader, %{values: values}) do
      if value in values do
        {:ok, value}
      else
        :error
      end
    end

    def dump(value, _dumper, %{values: values}) do
      if value in values do
        {:ok, value}
      else
        :error
      end
    end

    def equal?(a, b, _params), do: a == b
  end

  defmodule RangeType do
    @moduledoc """
    A parameterized type that validates integer values are within a range.
    """
    use Normandy.ParameterizedType

    def init(opts) do
      min = Keyword.get(opts, :min, 0)
      max = Keyword.get(opts, :max, 100)
      %{min: min, max: max}
    end

    def type(_params), do: :integer

    def cast(value, %{min: min, max: max}) when is_integer(value) do
      if value >= min and value <= max do
        {:ok, value}
      else
        {:error, message: "must be between #{min} and #{max}"}
      end
    end

    def cast(value, params) when is_binary(value) do
      case Integer.parse(value) do
        {int, ""} -> cast(int, params)
        _ -> :error
      end
    end

    def cast(_value, _params), do: :error

    def load(value, _loader, params), do: cast(value, params)
    def dump(value, _dumper, params), do: cast(value, params)

    def equal?(a, b, _params), do: a == b
  end

  describe "ParameterizedType.init/2" do
    test "initializes parameterized type with options" do
      type = ParameterizedType.init(EnumType, values: ["foo", "bar", "baz"])
      assert {:parameterized, {EnumType, %{values: ["foo", "bar", "baz"]}}} = type
    end

    test "passes field and schema info to init" do
      type = ParameterizedType.init(RangeType, min: 1, max: 10)
      assert {:parameterized, {RangeType, %{min: 1, max: 10}}} = type
    end
  end

  describe "EnumType parameterized type" do
    setup do
      params = %{values: ["draft", "published", "archived"]}
      {:ok, params: params}
    end

    test "casts valid string value", %{params: params} do
      assert {:ok, "draft"} = EnumType.cast("draft", params)
      assert {:ok, "published"} = EnumType.cast("published", params)
    end

    test "casts valid atom to string", %{params: params} do
      assert {:ok, "draft"} = EnumType.cast(:draft, params)
      assert {:ok, "published"} = EnumType.cast(:published, params)
    end

    test "returns error for invalid value", %{params: params} do
      assert :error = EnumType.cast("invalid", params)
      assert :error = EnumType.cast(:invalid, params)
      assert :error = EnumType.cast(123, params)
    end

    test "loads valid value", %{params: params} do
      loader = fn _type, value -> {:ok, value} end
      assert {:ok, "draft"} = EnumType.load("draft", loader, params)
    end

    test "returns error when loading invalid value", %{params: params} do
      loader = fn _type, value -> {:ok, value} end
      assert :error = EnumType.load("invalid", loader, params)
    end

    test "dumps valid value", %{params: params} do
      dumper = fn _type, value -> {:ok, value} end
      assert {:ok, "published"} = EnumType.dump("published", dumper, params)
    end

    test "returns error when dumping invalid value", %{params: params} do
      dumper = fn _type, value -> {:ok, value} end
      assert :error = EnumType.dump("invalid", dumper, params)
    end

    test "checks equality", %{params: params} do
      assert EnumType.equal?("draft", "draft", params)
      refute EnumType.equal?("draft", "published", params)
    end

    test "returns correct type", %{params: params} do
      assert :string = EnumType.type(params)
    end
  end

  describe "RangeType parameterized type" do
    setup do
      params = %{min: 0, max: 100}
      {:ok, params: params}
    end

    test "casts valid integer within range", %{params: params} do
      assert {:ok, 50} = RangeType.cast(50, params)
      assert {:ok, 0} = RangeType.cast(0, params)
      assert {:ok, 100} = RangeType.cast(100, params)
    end

    test "returns error with message for out of range value", %{params: params} do
      assert {:error, message: "must be between 0 and 100"} = RangeType.cast(101, params)
      assert {:error, message: "must be between 0 and 100"} = RangeType.cast(-1, params)
    end

    test "casts string to integer if within range", %{params: params} do
      assert {:ok, 42} = RangeType.cast("42", params)
    end

    test "returns error for string out of range", %{params: params} do
      assert {:error, message: "must be between 0 and 100"} = RangeType.cast("150", params)
    end

    test "returns error for invalid string", %{params: params} do
      assert :error = RangeType.cast("abc", params)
    end

    test "returns error for non-integer types", %{params: params} do
      assert :error = RangeType.cast(3.14, params)
      assert :error = RangeType.cast(:atom, params)
    end

    test "custom range parameters" do
      params = %{min: 18, max: 65}
      assert {:ok, 25} = RangeType.cast(25, params)
      assert {:error, _} = RangeType.cast(17, params)
      assert {:error, _} = RangeType.cast(66, params)
    end

    test "returns correct type", %{params: params} do
      assert :integer = RangeType.type(params)
    end
  end

  describe "default embed_as/2 implementation" do
    test "returns :self by default" do
      params = %{values: ["a", "b"]}
      assert :self = EnumType.embed_as(:json, params)
    end
  end

  describe "default equal?/3 implementation" do
    test "uses == for equality" do
      params = %{min: 0, max: 100}
      assert RangeType.equal?(42, 42, params)
      refute RangeType.equal?(42, 43, params)
    end
  end
end
