defmodule Normandy.Schema.ValidateFieldsTest do
  use ExUnit.Case, async: true

  alias Normandy.Validate

  defmodule Doc do
    use Normandy.Schema

    schema do
      field(:name, :string)
    end
  end

  describe "%Normandy.Validate{}" do
    test "has none of the changeset fields Normandy never used" do
      keys = %Validate{} |> Map.keys() |> MapSet.new()

      for key <- [:constraints, :filters, :prepare], do: refute(key in keys, "#{key} is back")
    end

    test "changes is a map before and after cast" do
      assert %Validate{}.changes == %{}
      assert %Validate{changes: %{}} = Validate.cast(%Doc{}, %{}, [:name])
    end

    test "an unknown field in cast names the known ones and no association" do
      error = assert_raise ArgumentError, fn -> Validate.cast(%Doc{}, %{"x" => 1}, [:x]) end

      assert error.message =~ "unknown field `:x` given to cast"
      assert error.message =~ ":name"
      refute error.message =~ "association"
    end
  end
end
