defmodule NormandyTest.TypePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Normandy.Type

  describe "property-based testing for primitive types" do
    property "integers can be cast, dumped, and loaded roundtrip" do
      check all(value <- integer()) do
        assert {:ok, ^value} = Type.cast(:integer, value)
        assert {:ok, ^value} = Type.dump(:integer, value)
        assert {:ok, ^value} = Type.load(:integer, value)
      end
    end

    property "integer strings can be cast" do
      check all(value <- integer()) do
        string_value = Integer.to_string(value)
        assert {:ok, ^value} = Type.cast(:integer, string_value)
      end
    end

    property "floats can be cast, dumped, and loaded roundtrip" do
      check all(value <- float()) do
        assert {:ok, ^value} = Type.cast(:float, value)
        assert {:ok, ^value} = Type.dump(:float, value)
        # load can convert integer to float
        assert {:ok, loaded} = Type.load(:float, value)
        assert is_float(loaded)
      end
    end

    property "booleans can be cast, dumped, and loaded roundtrip" do
      check all(value <- boolean()) do
        assert {:ok, ^value} = Type.cast(:boolean, value)
        assert {:ok, ^value} = Type.dump(:boolean, value)
        assert {:ok, ^value} = Type.load(:boolean, value)
      end
    end

    property "strings can be cast, dumped, and loaded roundtrip" do
      check all(value <- string(:printable)) do
        assert {:ok, ^value} = Type.cast(:string, value)
        assert {:ok, ^value} = Type.dump(:string, value)
        assert {:ok, ^value} = Type.load(:string, value)
      end
    end

    property "maps can be cast, dumped, and loaded roundtrip" do
      check all(
              keys <- list_of(atom(:alphanumeric), min_length: 0, max_length: 5),
              values <- list_of(string(:printable), length: length(keys))
            ) do
        map = Enum.zip(keys, values) |> Enum.into(%{})
        assert {:ok, ^map} = Type.cast(:map, map)
        assert {:ok, ^map} = Type.dump(:map, map)
        assert {:ok, ^map} = Type.load(:map, map)
      end
    end
  end

  describe "property-based testing for array types" do
    property "arrays of integers" do
      check all(list <- list_of(integer(), max_length: 20)) do
        assert {:ok, ^list} = Type.cast({:array, :integer}, list)
        assert {:ok, ^list} = Type.dump({:array, :integer}, list)
        assert {:ok, ^list} = Type.load({:array, :integer}, list)
      end
    end

    property "arrays of strings" do
      check all(list <- list_of(string(:printable), max_length: 10)) do
        assert {:ok, ^list} = Type.cast({:array, :string}, list)
        assert {:ok, ^list} = Type.dump({:array, :string}, list)
        assert {:ok, ^list} = Type.load({:array, :string}, list)
      end
    end

    property "arrays of booleans" do
      check all(list <- list_of(boolean(), max_length: 15)) do
        assert {:ok, ^list} = Type.cast({:array, :boolean}, list)
        assert {:ok, ^list} = Type.dump({:array, :boolean}, list)
        assert {:ok, ^list} = Type.load({:array, :boolean}, list)
      end
    end

    property "empty arrays work for any type" do
      check all(type <- member_of([:integer, :string, :boolean, :float])) do
        assert {:ok, []} = Type.cast({:array, type}, [])
        assert {:ok, []} = Type.dump({:array, type}, [])
        assert {:ok, []} = Type.load({:array, type}, [])
      end
    end
  end

  describe "property-based testing for map types" do
    property "maps with string values" do
      check all(
              keys <- list_of(atom(:alphanumeric), min_length: 0, max_length: 5),
              values <- list_of(string(:printable), length: length(keys))
            ) do
        map = Enum.zip(keys, values) |> Enum.into(%{})
        assert {:ok, ^map} = Type.cast({:map, :string}, map)
        assert {:ok, ^map} = Type.dump({:map, :string}, map)
        assert {:ok, ^map} = Type.load({:map, :string}, map)
      end
    end

    property "maps with integer values" do
      check all(
              keys <- list_of(atom(:alphanumeric), min_length: 0, max_length: 5),
              values <- list_of(integer(), length: length(keys))
            ) do
        map = Enum.zip(keys, values) |> Enum.into(%{})
        assert {:ok, ^map} = Type.cast({:map, :integer}, map)
        assert {:ok, ^map} = Type.dump({:map, :integer}, map)
        assert {:ok, ^map} = Type.load({:map, :integer}, map)
      end
    end
  end

  describe "property-based testing for type equality" do
    property "equal? is reflexive for integers" do
      check all(value <- integer()) do
        assert Type.equal?(:integer, value, value) == true
      end
    end

    property "equal? is reflexive for strings" do
      check all(value <- string(:printable)) do
        assert Type.equal?(:string, value, value) == true
      end
    end

    property "equal? is symmetric for integers" do
      check all(a <- integer(), b <- integer()) do
        assert Type.equal?(:integer, a, b) == Type.equal?(:integer, b, a)
      end
    end

    property "different integers are not equal" do
      check all(
              a <- integer(),
              b <- integer(),
              a != b
            ) do
        refute Type.equal?(:integer, a, b)
      end
    end
  end

  describe "property-based testing for error cases" do
    property "nil values are allowed for all basic types" do
      check all(type <- member_of([:integer, :string, :boolean, :float, :map, :binary])) do
        assert {:ok, nil} = Type.cast(type, nil)
        assert {:ok, nil} = Type.dump(type, nil)
        assert {:ok, nil} = Type.load(type, nil)
      end
    end
  end

  describe "type matching properties" do
    property ":any matches with any type" do
      check all(type <- member_of([:integer, :string, :boolean, :float])) do
        assert Type.match?(:any, type) == true
        assert Type.match?(type, :any) == true
      end
    end

    property "type matches itself" do
      check all(type <- member_of([:integer, :string, :boolean, :float, :map])) do
        assert Type.match?(type, type) == true
      end
    end
  end

  describe "composite type properties" do
    property "array types are recognized as composite" do
      check all(inner_type <- member_of([:integer, :string, :boolean])) do
        assert Type.composite?(:array) == true
        assert Type.primitive?({:array, inner_type}) == true
      end
    end

    property "map types are recognized as composite" do
      check all(inner_type <- member_of([:integer, :string, :boolean])) do
        assert Type.composite?(:map) == true
        assert Type.primitive?({:map, inner_type}) == true
      end
    end
  end
end
